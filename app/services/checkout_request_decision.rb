# Declining an open checkout request. Anyone who can approve it may decline it
# (admin or board member, the shop's resource manager, or an approver assigned to
# the tool, its shop, or the group), with a required reason that is shown to the
# requester. The decision runs under the same locks as cancellation and approval,
# so an approval and a decline cannot both apply to one request. The requester is
# told by Slack DM after the commit; a failed notification never undoes it.
class CheckoutRequestDecision
  REASON_MAX = 255

  def self.authorized?(actor, request)
    target = request.target
    return false unless actor && target && actor.id != request.member_id
    return true if actor.role.in?(%w[admin board_member]) || actor.manages_shop?(target.shop_id)
    return false unless actor.valid_for_checkout_request?

    approver = CheckoutApprover.find_by(member_id: actor.id)
    return false unless approver

    request.tool_group_id ? approver.can_approve_group?(target) : approver.can_approve_tool?(target)
  end

  def self.decline!(request:, actor:, reason:)
    reason = reason.to_s.strip
    raise Error::UnprocessableEntity.new('A reason is required to decline a request') if reason.blank?
    raise Error::UnprocessableEntity.new("Reason must be at most #{REASON_MAX} characters") if reason.length > REASON_MAX

    decide = lambda do
      request.reload
      raise Error::UnprocessableEntity.new('This checkout request is no longer open') unless request.open?
      raise Error::Forbidden.new('You are not authorized to decline this request') unless authorized?(actor.reload, request)

      request.update!(status: 'declined', decided_by_id: actor.id, decided_at: Time.current, decision_reason: reason)
    end

    with_locks(request, &decide)
    CheckoutNotificationJob.enqueue('decline', request.id)
    CheckoutCreation.notify { audit!(request, actor, reason) }
    request
  end

  # The system declines a request nobody recorded a checkout for after the last
  # reminder. It is a `declined` request with no deciding member, so the portal,
  # Slack and API treat it like any other decline; the requester is DMed and the
  # decision is audit-logged under its own event type. Returns true when this
  # call made the decision (false if the request was already resolved).
  def self.time_out!(request:, now: Time.current)
    days = (now.in_time_zone.to_date - request.request_date.in_time_zone.to_date).to_i
    reason = "Automatically declined: timed out with no checkout recorded after #{days} days. "              'Contact the board if you still need this checkout.'
    timed_out = false
    with_locks(request) do
      request.reload
      next unless request.open?

      request.update!(status: 'declined', decided_by_id: nil, decided_at: now, decision_reason: reason)
      timed_out = true
    end
    return false unless timed_out

    CheckoutNotificationJob.enqueue('decline', request.id)
    CheckoutCreation.notify { audit_timeout!(request, days) }
    true
  end

  # Same locks as approval and cancellation, so only one of them can apply.
  def self.with_locks(request, &block)
    if request.tool_group_id
      ToolGroupCheckout.with_request_locks(request, &block)
    else
      CatalogMutationLock.with([request.target&.shop_id]) do
        CheckoutMutationLock.with(member_id: request.member_id, tool_id: request.tool_id, &block)
      end
    end
  end
  private_class_method :with_locks

  def self.audit_timeout!(request, days)
    target = request.target
    Service::AuditLogger.log(
      log_type: 'member', event_type: 'tool_checkout_request_timed_out',
      resource_type: 'ToolCheckoutRequest', resource_id: request.id, actor: nil, subject: request.member,
      after_snapshot: { member_id: request.member_id.to_s, target_name: target&.name,
                        shop_name: target&.shop&.name, days_open: days },
      message_details: "shop: #{target&.shop&.name}, tool: #{target&.name}, timed out after #{days} days",
      slack_channel: Service::SlackConnector.logs_channel
    )
  end
  private_class_method :audit_timeout!

  # Recorded in the audit log (and posted to the logs channel) like other
  # checkout decisions. The requester's Slack DM is not itself logged.
  def self.audit!(request, actor, reason)
    target = request.target
    Service::AuditLogger.log(
      log_type: 'member', event_type: 'tool_checkout_request_declined',
      resource_type: 'ToolCheckoutRequest', resource_id: request.id, actor: actor, subject: request.member,
      after_snapshot: { member_id: request.member_id.to_s, target_name: target&.name,
                        shop_name: target&.shop&.name, declined_by: actor.fullname, reason: reason },
      message_details: "shop: #{target&.shop&.name}, tool: #{target&.name}, reason: #{reason}",
      slack_channel: Service::SlackConnector.logs_channel
    )
  end
  private_class_method :audit!
end
