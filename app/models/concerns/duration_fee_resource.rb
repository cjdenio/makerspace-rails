module DurationFeeResource
  extend ActiveSupport::Concern

  included do
    field :reservation_full_day, type: Mongoid::Boolean, default: false
    field :minimum_advance_notice_hours, type: Float, default: 2
    field :prohibit_same_day_reservations, type: Mongoid::Boolean, default: false
    validates :minimum_advance_notice_hours, numericality: { greater_than_or_equal_to: 0 }
    field :duration_fees, type: Array, default: []
    validate :valid_duration_fee_settings
  end

  private

  def valid_duration_fee_settings
    if reservation_full_day && (max_reservation_duration_hours.to_f < 24 || max_reservation_duration_hours.to_f % 24 != 0)
      errors.add(:max_reservation_duration_hours, "must be a multiple of 24 for full-day reservations")
    end
    return unless new_record? || duration_fees_changed?
    Array(duration_fees).each do |raw|
      fee = raw.to_h.stringify_keys
      option = InvoiceOption.where(id: fee["invoice_option_id"], resource_class: "fee", disabled: false).first
      errors.add(:duration_fees, "must select an enabled shop fee") unless option && option.amount.to_f.positive?
      next if ActiveModel::Type::Boolean.new.cast(fee["full_day"])

      minimum = fee["minimum_hours"].to_f
      maximum = fee["maximum_hours"].to_f
      unless minimum.positive? && maximum >= minimum && minimum % 0.5 == 0 && maximum % 0.5 == 0
        errors.add(:duration_fees, "must have positive half-hour minimum/maximum durations, with maximum at least minimum")
      end
    end
  end
end
