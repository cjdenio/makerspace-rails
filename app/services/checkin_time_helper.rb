# CheckinTimeHelper
#
# The 'checkins' MongoDB collection has two timestamp fields, 'timeOf'
# (current Doorboto integration) and 'time' (legacy). Neither field name
# reliably indicates units — both seconds-since-epoch and
# milliseconds-since-epoch values exist in BOTH fields, inconsistently,
# per record. Treating every value as milliseconds (the old assumption)
# causes seconds-based values to collapse into a 1-2 day window around
# January 1970.
#
# Normalization heuristic: for any date between 1970 and ~2286,
#   - seconds-since-epoch falls in the range 10^9 .. 10^10
#   - milliseconds-since-epoch falls in the range 10^12 .. 10^13
# These ranges differ by exactly 1000x with no overlap, so any threshold
# between 10^10 and 10^12 cleanly separates them. SECONDS_MS_THRESHOLD
# (10^10) is the natural ceiling for "seconds" — any larger value is ms.
#
# Usage:
#   CheckinTimeHelper.normalize_to_seconds(raw)  # => Integer seconds, or nil
#   CheckinTimeHelper.dual_unit_or_query(start_ms, end_ms)
#     # => array of conditions for use inside a Mongo '$or'
class CheckinTimeHelper
  SECONDS_MS_THRESHOLD = 10_000_000_000

  # Normalize a raw timestamp (seconds OR milliseconds since epoch) to seconds.
  # Returns nil for blank/zero/invalid input.
  def self.normalize_to_seconds(raw)
    return nil if raw.blank?

    value = raw.to_i
    return nil if value.zero?

    value > SECONDS_MS_THRESHOLD ? value / 1000 : value
  end

  # Build an array of Mongo query conditions matching `fields` against the
  # range [start_ms, end_ms] under BOTH unit interpretations (milliseconds
  # and seconds), since a given record's field may be stored in either unit.
  #
  # Intended for use as the value of a '$or' key:
  #   query['$or'] = CheckinTimeHelper.dual_unit_or_query(start_ms, end_ms)
  #
  # start_ms / end_ms may each independently be nil for an open-ended range,
  # but at least one of the two must be present.
  def self.dual_unit_or_query(start_ms, end_ms, fields: %w[timeOf time])
    start_sec = start_ms.nil? ? nil : start_ms / 1000
    end_sec   = end_ms.nil?   ? nil : end_ms / 1000

    fields.flat_map do |field|
      [
        range_condition(field, start_ms,  end_ms),
        range_condition(field, start_sec, end_sec),
      ]
    end
  end

  def self.range_condition(field, gte, lte)
    range = {}
    range['$gte'] = gte unless gte.nil?
    range['$lte'] = lte unless lte.nil?
    { field => range }
  end
  private_class_method :range_condition
end
