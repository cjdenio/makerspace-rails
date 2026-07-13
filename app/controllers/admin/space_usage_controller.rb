require "set"

class Admin::SpaceUsageController < AdminController

  # GET /api/admin/space_usage
  #
  # Unique member door checkins per day or per calendar month.
  # One checkin per card UID per day is counted (deduped by uid+date).
  # Card UIDs are joined to member IDs via the cards collection.
  #
  # Params:
  #   granularity  'day' | 'month' (default: 'month')
  #   year         integer — required for granularity=day; optional for month
  #   month        integer 1-12 — combined with year for daily view
  #   rolling      '30' — return last 30 days regardless of year/month params
  #
  # Response: [{ date: "2024-01" | "2024-01-15", unique_members: 42 }, ...]
  def index
    granularity = params[:granularity] == 'day' ? :day : :month

    # Build time range
    if params[:rolling] == '30'
      start_time = (Date.today - 30.days).to_time.to_i * 1000
      end_time   = Time.now.to_i * 1000
    elsif params[:year].present?
      year = params[:year].to_i
      if granularity == :day && params[:month].present?
        month      = params[:month].to_i
        start_date = Date.new(year, month, 1)
        end_date   = start_date.end_of_month
      else
        start_date = Date.new(year, 1, 1)
        end_date   = Date.new(year, 12, 31)
      end
      start_time = start_date.to_time.to_i * 1000
      end_time   = end_date.to_time.to_i * 1000 + 86_399_999 # end of day
    else
      # Default: current year
      start_time = Date.new(Date.today.year, 1, 1).to_time.to_i * 1000
      end_time   = Time.now.to_i * 1000
    end

    checkins_col = Mongoid.default_client[:checkins]
    cards_col    = Mongoid.default_client[:cards]

    # Build a uid → member_id lookup from the cards collection
    uid_to_member = {}
    cards_col.find({}, projection: { uid: 1, member_id: 1 }).each do |doc|
      uid_to_member[doc['uid'].to_s] = doc['member_id'].to_s if doc['uid'].present? && doc['member_id'].present?
    end

    # Fetch raw checkins in range — query both timeOf and time fields under
    # BOTH unit interpretations, since either field may store seconds or
    # milliseconds depending on the record. See CheckinTimeHelper.
    raw = checkins_col.find(
      '$or' => CheckinTimeHelper.dual_unit_or_query(start_time, end_time)
    ).projection(uid: 1, timeOf: 1, time: 1).to_a

    # Deduplicate: one entry per (member_id, date_bucket)
    seen = {}
    raw.each do |doc|
      uid       = doc['uid'].to_s
      member_id = uid_to_member[uid]
      next if member_id.blank?

      ts_raw  = doc['timeOf'].presence || doc['time']
      seconds = CheckinTimeHelper.normalize_to_seconds(ts_raw)
      next if seconds.nil?

      date = Time.at(seconds).utc.to_date
      key  = granularity == :day ? date.strftime('%Y-%m-%d') : date.strftime('%Y-%m')

      seen[key] ||= Set.new
      seen[key].add(member_id)
    end

    # Build sorted result
    data = seen.map { |date_key, members| { date: date_key, unique_members: members.size } }
               .sort_by { |d| d[:date] }

    render plain: data.to_json, content_type: "application/json"
  end

  # GET /api/admin/space_usage/date_range
  # Returns the earliest and latest checkin dates so the UI
  # can populate the year/month selectors accurately.
  #
  # Can't use .sort(field: 1).limit(1) to find earliest/latest — under mixed
  # units, a 2018 record stored in milliseconds (~1.5e12) sorts AFTER a 2023
  # record stored in seconds (~1.7e9), even though 2018 is chronologically
  # earlier. Instead, fetch all distinct values, normalize each to seconds,
  # and take min/max of the normalized values. distinct() over a few thousand
  # values is fast.
  def date_range
    checkins_col = Mongoid.default_client[:checkins]

    all_seconds = %w[timeOf time].flat_map do |field|
      checkins_col.find(field => { '$exists' => true, '$ne' => nil })
                  .distinct(field)
                  .map { |raw| CheckinTimeHelper.normalize_to_seconds(raw) }
                  .compact
    end

    if all_seconds.empty?
      render plain: { earliest_year: Date.today.year, latest_year: Date.today.year }.to_json, content_type: "application/json" and return
    end

    earliest_year = Time.at(all_seconds.min).utc.year
    latest_year   = Time.at(all_seconds.max).utc.year

    render plain: { earliest_year: earliest_year, latest_year: latest_year }.to_json, content_type: "application/json"
  end
end
