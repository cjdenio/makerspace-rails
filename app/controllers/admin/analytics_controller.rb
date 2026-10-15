class Admin::AnalyticsController < AdminController

  # GET /api/admin/analytics
  # Summary counts.
  def index
    analytics = Service::Analytics::Members.summary_counts.merge(
      Service::Analytics::Invoices.summary_counts
    ).merge(
      members_with_expiring_payment_methods: Service::CardExpirationCheck.expiring_member_count,
    )
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

  # GET /api/admin/analytics/member_losses
  # Members lost (expirationTime already passed) grouped by month -- the
  # month a membership actually lapsed, not merely when it was due to.
  #
  # Params:
  #   year (integer, optional) — filter to a single calendar year
  #   start_date (YYYY-MM-DD, optional) — lower bound (defaults to 2016-08-01)
  #   end_date   (YYYY-MM-DD, optional) — upper bound (defaults to today)
  #
  # Response: [{ month: "2024-01", count: 3 }, ...]
  def member_losses
    if params[:year].present?
      year       = params[:year].to_i
      start_date = Date.new(year, 1, 1)
      end_date   = Date.new(year, 12, 31)
    else
      start_date = parse_date_param(:start_date, default: Date.parse('2016-08-01'))
      end_date   = parse_date_param(:end_date,   default: Date.today)
    end

    render json: Service::Analytics::Members.lost_members_by_month(start_date: start_date, end_date: end_date)
  end

  # GET /api/admin/analytics/active_members
  # Active member count per month derived directly from the Member table.
  # No dependency on MembershipSnapshot or any scheduled job.
  #
  # For each month in the range, counts members where:
  #   startDate <= end_of_month  AND  expirationTime >= end_of_month_ms
  #   AND status is activeMember or pending
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

    data = Service::Analytics::Members.active_members_by_month(
      start_date: start_date,
      end_date: end_date,
      statuses: Member::ACTIVE_MEMBERSHIP_STATUSES
    )

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
      year       = params[:year].to_i
      start_time = Time.new(year, 1, 1)
      end_time   = Time.new(year + 1, 1, 1)
      credits = credits.where(:created_at.gte => start_time, :created_at.lt => end_time)
      tasks   = tasks.where(:completed_at.gte => start_time, :completed_at.lt => end_time)
    end

    # Keep the global pending count in the same round-trip, but let MongoDB
    # discard approved credits outside the requested year before $facet fans
    # the input out to its branches. This permits the status/created_at index
    # to bound the approved branch of the initial $or.
    credit_input_selector = if params[:year].present?
      { '$or' => [{ 'status' => 'pending' }, credits.selector] }
    else
      { 'status' => { '$in' => %w[approved pending] } }
    end

    credit_facets = VolunteerCredit.collection.aggregate([
      { '$match' => credit_input_selector },
      { '$facet' => {
        'by_month' => [
          { '$match' => credits.selector },
          { '$group' => {
            '_id' => { 'year' => { '$year' => '$created_at' }, 'month' => { '$month' => '$created_at' } },
            'count' => { '$sum' => 1 },
            'total_value' => { '$sum' => '$credit_value' }
          } },
          { '$sort' => { '_id.year' => 1, '_id.month' => 1 } }
        ],
        'top_volunteers' => [
          { '$match' => credits.selector },
          { '$group' => {
            '_id' => '$member_id', 'credit_count' => { '$sum' => 1 },
            'total_value' => { '$sum' => '$credit_value' }
          } },
          { '$sort' => { 'total_value' => -1 } },
          { '$limit' => 10 }
        ],
        'totals' => [
          { '$match' => credits.selector },
          { '$group' => { '_id' => nil, 'count' => { '$sum' => 1 }, 'value' => { '$sum' => '$credit_value' } } }
        ],
        'pending' => [
          { '$match' => { 'status' => 'pending' } },
          { '$count' => 'count' }
        ]
      } }
    ]).first || {}

    credits_by_month = credit_facets.fetch('by_month', []).map do |r|
      {
        month:       format('%04d-%02d', r['_id']['year'], r['_id']['month']),
        count:       r['count'],
        total_value: r['total_value'].to_f.round(2)
      }
    end

    # Tasks completed by month
    tasks_pipeline = [
      { '$match' => tasks.where(:completed_at.ne => nil).selector },
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

    top_rows       = credit_facets.fetch('top_volunteers', [])
    top_member_ids = top_rows.map { |r| r['_id'] }
    top_members    = Member.in(id: top_member_ids).index_by(&:id)

    top_volunteers = top_rows.filter_map do |r|
      m = top_members[r['_id']]
      next if m.nil?
      { name: m.fullname, credits: r['credit_count'], value: r['total_value'].to_f.round(2) }
    end

    totals = credit_facets.fetch('totals', []).first || {}
    render json: {
      credits_by_month:   credits_by_month,
      tasks_by_month:     tasks_by_month,
      top_volunteers:     top_volunteers,
      total_credits:      totals.fetch('count', 0),
      total_credit_value: totals.fetch('value', 0).to_f.round(2),
      pending_credits:    credit_facets.fetch('pending', []).first&.fetch('count', 0) || 0
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
