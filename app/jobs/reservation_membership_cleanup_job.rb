class ReservationMembershipCleanupJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(resource_id, cleanup_type, resource_type = "Member")
    resource = resource_type.constantize.find(resource_id)
    case cleanup_type
    when "revoked"
      ReservationLifecycleService.cancel_current_and_future!(
        resource,
        reason: "Membership was revoked"
      )
    when "subscription_ended", "group_subscription_ended"
      ReservationLifecycleService.cancel_beyond_membership!(
        resource,
        reason: resource_type == "Group" ?
          "Household recurring membership was cancelled" :
          "Recurring membership was cancelled"
      )
    end
  rescue Mongoid::Errors::DocumentNotFound
    nil
  end
end
