class ReservationBlackout
  include Mongoid::Document
  include Mongoid::Timestamps
  include ActiveModel::Serializers::JSON

  RECURRENCES = %w[daily weekly].freeze
  TIME_PATTERN = /\A(?:[01]\d|2[0-3]):(?:00|30)\z/

  field :title, type: String
  field :recurrence, type: String
  field :weekday, type: Integer
  field :start_time, type: String
  field :end_time, type: String
  field :start_date, type: Date
  field :end_date, type: Date

  belongs_to :shop
  belongs_to :created_by, class_name: "Member"

  index({ shop_id: 1, recurrence: 1, start_date: 1, end_date: 1 })

  before_validation :normalize_values

  validates :title, :shop, :created_by, presence: true
  validates :recurrence, inclusion: { in: RECURRENCES }
  validates :start_time, :end_time, format: { with: TIME_PATTERN }
  validates :weekday,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 6 },
    allow_nil: true
  validate :weekly_has_weekday
  validate :daily_has_no_weekday
  validate :date_bounds_are_ordered

  def occurs_on?(date)
    date = date.to_date
    return false if start_date.present? && date < start_date
    return false if end_date.present? && date > end_date

    recurrence == "daily" || (recurrence == "weekly" && date.wday == weekday)
  end

  def occurrence_on(date)
    return nil unless occurs_on?(date)

    start_hour, start_minute = parse_clock(start_time)
    end_hour, end_minute = parse_clock(end_time)
    occurrence_start = ReservationService::ZONE.local(
      date.year, date.month, date.day, start_hour, start_minute
    )
    occurrence_end = ReservationService::ZONE.local(
      date.year, date.month, date.day, end_hour, end_minute
    )
    if start_time == end_time
      occurrence_end = occurrence_start + 1.day
    elsif (end_hour * 60 + end_minute) < (start_hour * 60 + start_minute)
      next_date = date + 1.day
      occurrence_end = ReservationService::ZONE.local(
        next_date.year, next_date.month, next_date.day, end_hour, end_minute
      )
    end

    # A nonexistent DST wall time can normalize forward until distinct clock
    # values represent the same instant. Such an interval contains no time;
    # only explicitly equal clock values represent a 24-hour occurrence.
    return nil unless occurrence_end > occurrence_start

    {
      blackout: self,
      start_at: occurrence_start.utc,
      end_at: occurrence_end.utc
    }
  end

  def occurrences_overlapping(range_start, range_end)
    return [] if range_start.blank? || range_end.blank? || range_end <= range_start

    local_start_date = range_start.in_time_zone(ReservationService::ZONE).to_date
    local_end_date = range_end.in_time_zone(ReservationService::ZONE).to_date
    ((local_start_date - 1.day)..local_end_date).filter_map do |date|
      occurrence = occurrence_on(date)
      next unless occurrence
      next unless occurrence[:start_at] < range_end && occurrence[:end_at] > range_start

      occurrence
    end
  end

  def self.occurrences_overlapping(shop_id:, start_at:, end_at:)
    where(shop_id: shop_id).flat_map do |blackout|
      blackout.occurrences_overlapping(start_at, end_at)
    end.sort_by { |occurrence| occurrence[:start_at] }
  end

  private

  def normalize_values
    self.title = title.to_s.strip
    self.recurrence = recurrence.to_s.downcase
    self.start_time = normalize_clock(start_time)
    self.end_time = normalize_clock(end_time)
    self.weekday = nil if recurrence == "daily"
  end

  def normalize_clock(value)
    match = value.to_s.strip.match(/\A(\d{1,2}):(\d{2})\z/)
    return value.to_s.strip unless match

    format("%02d:%02d", match[1].to_i, match[2].to_i)
  end

  def parse_clock(value)
    value.split(":").map(&:to_i)
  end

  def weekly_has_weekday
    errors.add(:weekday, "is required for weekly recurrence") if recurrence == "weekly" && weekday.nil?
  end

  def daily_has_no_weekday
    errors.add(:weekday, "must be blank for daily recurrence") if recurrence == "daily" && weekday.present?
  end

  def date_bounds_are_ordered
    return if start_date.blank? || end_date.blank?
    errors.add(:end_date, "must be on or after the start date") if end_date < start_date
  end
end
