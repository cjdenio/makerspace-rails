class CheckoutCreation
  def self.authorized?(actor, tool)
    actor && tool && SlackCheckoutModal.membership_error(actor).nil? &&
      (actor.status != "pending" || tool.allow_pending) &&
      (actor.role.in?(%w[admin board_member]) || actor.manages_shop?(tool.shop_id) ||
        (actor.valid_for_checkout_request? && CheckoutApprover.find_by(member_id: actor.id)&.can_approve_tool?(tool)))
  end

  def self.create!(actor_id:, member_id:, tool_id:, shop_id:, source:, request_id: nil, defer_notifications: false)
    actor = Member.find_by(id: actor_id)
    tool = Tool.find_by(id: tool_id)
    create_checkout = -> do
      create_under_checkout_lock(actor_id: actor_id, member_id: member_id, tool_id: tool_id,
        shop_id: shop_id, source: source, request_id: request_id,
        defer_notifications: defer_notifications) { yield if block_given? }
    end
    checkout = CatalogMutationLock.with([tool&.shop_id]) do
      if additional_approver_authority_required?(actor, tool)
        CheckoutApproverMutationLock.with(member_id: actor_id, &create_checkout)
      else
        create_checkout.call
      end
    end
    notify { ToolCheckoutSlackCanvasSyncJob.perform_later(checkout.tool.shop_id.to_s, checkout.id.to_s, 'add') }
    Array(checkout.reconciled_requests).each { |request| notify { request.refresh_closed_announcement } }
    if defer_notifications
      CheckoutNotificationJob.enqueue("approval", checkout.id)
    else
      deliver_notifications(checkout, invite: true)
    end
    checkout
  end

  def self.create_under_checkout_lock(actor_id:, member_id:, tool_id:, shop_id:, source:, request_id:,
    defer_notifications:)
    CheckoutMutationLock.with(member_id: member_id, tool_id: tool_id) do
      yield if block_given? # Recheck the initiating Slack identity under the same lock.
      actor = Member.find_by(id: actor_id)
      member = Member.find_by(id: member_id)
      tool = Tool.find_by(id: tool_id)
      raise Error::Forbidden.new("You are not authorized to approve checkouts for this tool") unless authorized?(actor, tool)
      raise Error::UnprocessableEntity.new("Tool unavailable") unless member && tool.shop_id.to_s == shop_id.to_s
      request = ToolCheckoutRequest.find_by(id: request_id) if request_id
      if request_id && (!request&.open? || request.member_id != member.id || request.tool_id != tool.id)
        raise Error::UnprocessableEntity.new("This checkout request is no longer open or available")
      end
      error = ToolCheckoutRequestEligibility.new(member: member, tool: tool, open_request_tool_ids: []).error
      raise Error::UnprocessableEntity.new(error) if error
      ToolCheckout.with_session do |session|
        session.with_transaction do
          checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
            signed_off_via: source, checked_out_at: Time.current, checkout_request_id: request&.id,
            defer_users_channel_invitation: true, defer_group_callbacks: true)
          notify { CheckoutApproverCredit.award!(checkout) }
          checkout.reconciled_requests = ToolGroupCheckout.reconcile!(member.id)
          checkout
        end
      ensure
        session.end_session
      end
    end
  end

  def self.deliver_notifications(checkout, invite: false)
    if checkout.active?
      notify { checkout.invite_member_to_users_channel } if invite
      notify { checkout.send_checkout_slack_notification }
      notify { checkout.announce_checkout_success }
    end
    notify do
      ToolCheckoutRequest.where(checked_out_id: checkout.id, reminder_open: true).each do |request|
        CheckoutRequestReminder.finalize!(request)
      end
    end
    notify do
      Service::AuditLogger.log(log_type: "member", event_type: "tool_checkout_created",
        resource_type: "ToolCheckout", resource_id: checkout.id, actor: checkout.approved_by, subject: checkout.member,
        after_snapshot: { member_id: checkout.member_id.to_s, tool_id: checkout.tool_id.to_s,
          shop_name: checkout.tool.shop.name, tool_name: checkout.tool.name,
          approved_by: checkout.approved_by.fullname, signed_off_via: checkout.signed_off_via },
        message_details: "shop: #{checkout.tool.shop.name}, tool: #{checkout.tool.name}",
        slack_channel: Service::SlackConnector.logs_channel)
    end
    checkout
  end

  def self.notify
    yield
  rescue => error
    begin
      Service::ErrorReporter.notify("Checkout notification failed", context: { error_class: error.class.name })
    rescue
      Rails.logger.warn("[Checkout] notification reporting failed")
    end
  end

  def self.additional_approver_authority_required?(actor, tool)
    actor && tool && !actor.role.in?(%w[admin board_member]) && !actor.manages_shop?(tool.shop_id)
  end
  private_class_method :create_under_checkout_lock, :additional_approver_authority_required?
end
