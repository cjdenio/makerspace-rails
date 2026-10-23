class ReservationLifecycleService
  class << self
    def cancellation_impact(resource)
      members_for(resource).flat_map do |member|
        next [] if alternative_subscription_active?(member, resource)
        expiration = member.membership_expires_at
        cancellation_threshold = [expiration || Time.current, Time.current].max

        Reservation.blocking.where(
          member_id: member.id,
          :end_at.gt => cancellation_threshold
        ).to_a
      end.uniq { |reservation| reservation.id.to_s }
    end

    def cancel_beyond_membership!(resource, reason:)
      cancel_reservations!(cancellation_impact(resource), reason: reason)
    end

    def cancel_current_and_future!(member, reason:)
      reservations = Reservation.blocking.where(
        member_id: member.id,
        :end_at.gt => Time.current
      ).to_a
      cancel_reservations!(reservations, reason: reason)
    end

    private

    def members_for(resource)
      case resource
      when Member
        [resource]
      when Group
        ([resource.member] + resource.active_members.to_a).compact.uniq { |member| member.id.to_s }
      else
        []
      end
    end

    def alternative_subscription_active?(member, resource)
      if resource.is_a?(Member)
        household = member.group
        household.present? && (household.subscription == true || household.subscription_id.present?)
      elsif resource.is_a?(Group)
        member.subscription == true || member.subscription_id.present?
      else
        member.active_membership_subscription?
      end
    rescue Mongoid::Errors::DocumentNotFound
      false
    end

    def cancel_reservations!(reservations, reason:)
      reservations.each do |reservation|
        ReservationService.cancel!(
          reservation: reservation,
          actor: nil,
          reason: reason
        )
      end
      reservations
    end
  end
end
