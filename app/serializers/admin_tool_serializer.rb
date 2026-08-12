class AdminToolSerializer < ToolSerializer
  MANAGEMENT_ONLY_FIELDS = %i[
    disabled
    allow_pending
    announce
    announce_channel
    users_channel
    reservable
    max_concurrent_reservations
    reservation_horizon_days
    max_reservation_duration_hours
    reservation_requires_approval
    reservation_prerequisite_tool_ids
    effective_reservation_prerequisite_ids
    reservation_prerequisite_names
  ].freeze

  def attributes(*args)
    values = super
    return values if management_access?

    MANAGEMENT_ONLY_FIELDS.each { |field| values.delete(field) }
    values
  end

  private

  def management_access?
    return true if instance_options[:global_management]

    Array(instance_options[:management_shop_ids]).map(&:to_s).include?(object.shop_id.to_s)
  end
end
