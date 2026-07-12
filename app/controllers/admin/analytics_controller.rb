class Admin::AnalyticsController < AdminController

  # GET /api/admin/analytics
  # Summary counts — existing endpoint, unchanged.
  def index
    analytics = {
      total_members:      Service::Analytics::Members.query_total_members.count,
      new_members:        Service::Analytics::Members.query_new_members.count,
      subscribed_members: Service::Analytics::Members.query_braintree_members.count,
      past_due_invoices:  Service::Analytics::Invoices.query_past_due.count,
      refunds_pending:    Service::Analytics::Invoices.query_refunds_pending.count,
    }
    render json: analytics.deep_transform_keys! { |k| k.to_s.camelize(:lower) }
  end

  # GET /api/admin/analytics/member_growth
  # New member sign-ups grouped by month.
  #
  # Params:
  #   year (integer, optional) — filter to a single calendar year
  #   start_date (YYYY-MM-DD, optional) — lower bound (defaults to 2016-08-01)
  #   end_date   (YYYY-MM-DD, optional) — upper bound (defaults to today)
  #
  # Response: [{ month: "2024-01", count: 12 }, ...]
  def member_growth
    # Build match clause — only filter by date when a year is explicitly requested
    match_clause = {
      'startDate' => { '$ne' => nil },
      'firstname' => { '$ne' => 'Landlord' },
      'lastname'  => { '$ne' => 'Fob' }
    }

    if params[:year].present?
      year = params[:year].to_i
      match_clause['startDate'] = {
        '$gte' => Date.new(year, 1, 1).to_time,
        '$lte' => Date.new(year, 12, 31).end_of_day
      }
    elsif params[:start_date].present? || params[:end_date].present?
      start_date = parse_date_param(:start_date, default: Date.parse('2016-08-01'))
      end_date   = parse_date_param(:end_date,   default: Date.today)
      match_clause['startDate'] = { '$gte' => start_date.to_time, '$lte' => end_date.end_of_day }
    end

    # MongoDB aggregation: group Member#startDate by year-month
    pipeline = [
      {
        '$match' => match_clause
      },
      {
        '$group' => {
          '_id' => {
            'year'  => { '$year'  => '$startDate' },
            'month' => { '$month' => '$startDate' }
          },
          'count' => { '$sum' => 1 }
        }
      },
      { '$sort' => { '_id.year' => 1, '_id.month' => 1 } }
    ]

    rows = Member.collection.aggregate(pipeline).to_a

    data = rows.map do |r|
      month_str = format('%04d-%02d', r['_id']['year'], r['_id']['month'])
      { month: month_str, count: r['count'] }
    end

    render json: data
  end

  # GET /api/admin/analytics/active_members
  # Active member count per month derived directly from the Member table.
  # No dependency on MembershipSnapshot or any scheduled job.
  #
  # For each month in the range, counts members where:
  #   startDate <= end_of_month  AND  expirationTime >= end_of_month_ms
  #   AND status == 'activeMember'
  #
  # Params:
  #   year (integer, optional) — filter to a calendar year
  #
  # Response: [{ date: "2024-01", count: 142 }, ...]
  def active_members
    # Determine date range
    if params[:year].present?
      year       = params[:year].to_i
      start_date = Date.new(year, 1, 1)
      end_date   = Date.new(year, 12, 31)
    else
      # Default: from the earliest member startDate to today
      earliest = Member.where(:startDate.ne => nil).min(:startDate)
      start_date = earliest ? earliest.to_date.beginning_of_month : 3.years.ago.to_date
      end_date   = Date.today
    end

    # Walk month by month and count active members at end of each month
    data      = []
    cursor    = start_date.beginning_of_month
    end_month = end_date.beginning_of_month

    while cursor <= end_month
      month_end    = cursor.end_of_month
      month_end_ms = month_end.to_time.to_i * 1000

      count = Member.where(
        :startDate.lte      => month_end.to_time,
        :expirationTime.gte => month_end_ms,
        status:               'activeMember'
      ).count

      data << { date: cursor.strftime('%Y-%m'), count: count }
      cursor = cursor >> 1  # advance one month
    end

    render json: data
  end

  # GET /api/admin/analytics/volunteer_summary
  # Volunteer activity over time.
  #
  # Params:
  #   year (integer, optional) — filter to a calendar year
  #
  # Response:
  #   {
  #     credits_by_month:    [{ month: "2024-01", count: 8,  total_value: 9.5 }, ...],
  #     tasks_by_month:      [{ month: "2024-01", count: 3 }, ...],
  #     top_volunteers:      [{ name: "Jane Doe", credits: 14, value: 16.0 }, ...],
  #     total_credits:       42,
  #     total_credit_value:  48.5,
  #     pending_credits:     2
  #   }
  def volunteer_summary
    credits = VolunteerCredit.where(status: 'approved')
    tasks   = VolunteerTask.where(status: 'completed')

    if params[:year].present?
      year  = params[:year].to_i
      start = Time.new(year, 1, 1)
      fin   = Time.new(year, 12, 31, 23, 59, 59)
      credits = credits.where(:created_at.gte => start, :created_at.lte => fin)
      tasks   = tasks.where(:completed_at.gte => start, :completed_at.lte => fin)
    end

    # Credits by month
    credits_pipeline = [
      { '$match' => credits.selector },
      {
        '$group' => {
          '_id'         => { 'year' => { '$year' => '$created_at' }, 'month' => { '$month' => '$created_at' } },
          'count'       => { '$sum' => 1 },
          'total_value' => { '$sum' => '$credit_value' }
        }
      },
      { '$sort' => { '_id.year' => 1, '_id.month' => 1 } }
    ]

    credits_by_month = VolunteerCredit.collection.aggregate(credits_pipeline).map do |r|
      {
        month:       format('%04d-%02d', r['_id']['year'], r['_id']['month']),
        count:       r['count'],
        total_value: r['total_value'].to_f.round(2)
      }
    end

    # Tasks completed by month
    tasks_pipeline = [
      { '$match' => { 'status' => 'completed', 'completed_at' => { '$ne' => nil } } },
      {
        '$group' => {
          '_id'   => { 'year' => { '$year' => '$completed_at' }, 'month' => { '$month' => '$completed_at' } },
          'count' => { '$sum' => 1 }
        }
      },
      { '$sort' => { '_id.year' => 1, '_id.month' => 1 } }
    ]

    tasks_by_month = VolunteerTask.collection.aggregate(tasks_pipeline).map do |r|
      {
        month: format('%04d-%02d', r['_id']['year'], r['_id']['month']),
        count: r['count']
      }
    end

    # Top 10 volunteers by credit value
    top_pipeline = [
      { '$match' => credits.selector },
      {
        '$group' => {
          '_id'         => '$member_id',
          'credit_count' => { '$sum' => 1 },
          'total_value'  => { '$sum' => '$credit_value' }
        }
      },
      { '$sort' => { 'total_value' => -1 } },
      { '$limit' => 10 }
    ]

    top_rows       = VolunteerCredit.collection.aggregate(top_pipeline).to_a
    top_member_ids = top_rows.map { |r| r['_id'] }
    top_members    = Member.in(id: top_member_ids).index_by(&:id)

    top_volunteers = top_rows.filter_map do |r|
      m = top_members[r['_id']]
      next if m.nil?
      { name: m.fullname, credits: r['credit_count'], value: r['total_value'].to_f.round(2) }
    end

    render json: {
      credits_by_month:   credits_by_month,
      tasks_by_month:     tasks_by_month,
      top_volunteers:     top_volunteers,
      total_credits:      credits.count,
      total_credit_value: credits.sum(:credit_value).to_f.round(2),
      pending_credits:    VolunteerCredit.where(status: 'pending').count
    }
  end

  private

  def parse_date_param(key, default:)
    return default if params[key].blank?
    Date.parse(params[key].to_s)
  rescue ArgumentError
    default
  end
end
