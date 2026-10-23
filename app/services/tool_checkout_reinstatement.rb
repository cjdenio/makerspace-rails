# Deliberate path for restoring a member's tool checkout after a revocation.
#
# The revoked ToolCheckout is never modified or deleted. Reinstatement creates
# a fresh checkout (linked through reinstated_from_id) and writes a
# tool_checkout_reinstated audit entry. Authorization (admin/board) is enforced
# here as well as in the controller, so no other caller can bypass it.
class ToolCheckoutReinstatement
  def self.reinstate!(actor:, revoked_checkout:, reason:)
    reason = reason.to_s.strip
    raise Error::Forbidden.new("Only admins and board members can reinstate a checkout") unless actor&.role.in?(%w[admin board_member])
    raise Error::UnprocessableEntity.new("Reinstatement reason is required") if reason.blank?

    tool = revoked_checkout.tool
    checkout = CatalogMutationLock.with([tool&.shop_id]) do
      CheckoutMutationLock.with(member_id: revoked_checkout.member_id, tool_id: revoked_checkout.tool_id) do
        create_under_lock(actor, revoked_checkout.reload, reason)
      end
    end
    deliver_notifications(checkout, actor, revoked_checkout, reason)
    checkout
  end

  def self.create_under_lock(actor, revoked, reason)
    raise Error::UnprocessableEntity.new("This checkout has not been revoked") if revoked.revoked_at.nil?
    if revoked.revocation_cleanup_pending?
      raise Error::UnprocessableEntity.new("The revocation is still being finalized. Please try again shortly.")
    end
    if ToolCheckout.where(reinstated_from_id: revoked.id).exists?
      raise Error::UnprocessableEntity.new("This checkout has already been reinstated")
    end

    member = revoked.member
    tool = revoked.tool
    error = ToolCheckoutRequestEligibility.new(member: member, tool: tool, open_request_tool_ids: [],
      reinstating: true).error
    raise Error::UnprocessableEntity.new(error) if error

    ToolCheckout.with_session do |session|
      session.with_transaction do
        checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
          signed_off_via: "portal", checked_out_at: Time.current, reinstated_from_id: revoked.id,
          reinstatement_reason: reason, reinstated_by_id: actor.id, reinstated_at: Time.current,
          defer_users_channel_invitation: true, defer_group_callbacks: true)
        ToolCheckout.supersede_expired!(checkout)
        CheckoutCreation.notify { CheckoutApproverCredit.award!(checkout) }
        checkout.reconciled_requests = ToolGroupCheckout.reconcile!(member.id)
        checkout
      end
    ensure
      session.end_session
    end
  end

  def self.deliver_notifications(checkout, actor, revoked, reason)
    CheckoutCreation.notify do
      ToolCheckoutSlackCanvasSyncJob.perform_later(checkout.tool.shop_id.to_s, checkout.id.to_s, "add")
    end
    Array(checkout.reconciled_requests).each { |request| CheckoutCreation.notify { request.refresh_closed_announcement } }
    CheckoutCreation.notify { checkout.invite_member_to_users_channel }
    CheckoutCreation.notify { checkout.send_checkout_slack_notification }
    CheckoutCreation.notify do
      Service::AuditLogger.log(log_type: "member", event_type: "tool_checkout_reinstated",
        resource_type: "ToolCheckout", resource_id: checkout.id, actor: actor, subject: checkout.member,
        after_snapshot: { tool_id: checkout.tool_id.to_s, reinstated_from_id: revoked.id.to_s,
          revoked_at: revoked.revoked_at&.iso8601, reinstatement_reason: reason,
          shop_name: checkout.tool.shop.name, tool_name: checkout.tool.name },
        message_details: "shop: #{checkout.tool.shop.name}, tool: #{checkout.tool.name}",
        slack_channel: Service::SlackConnector.logs_channel)
    end
  end
  private_class_method :create_under_lock, :deliver_notifications
end
