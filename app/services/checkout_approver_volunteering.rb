class CheckoutApproverVolunteering
  def self.create!(member:, tool:, note: nil)
    return ToolGroupVolunteering.create!(member: member, group: tool, note: note) if tool.is_a?(ToolGroup)
    request = CheckoutMutationLock.with(member_id: member.id, tool_id: tool.id) do
      member.reload
      raise Error::UnprocessableEntity.new("You must have an active checkout for this tool") unless
        ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
      raise Error::UnprocessableEntity.new("Your membership must be active and current") unless member.valid_for_checkout_request?
      if CheckoutApprover.find_by(member_id: member.id)&.can_approve_tool?(tool)
        raise Error::UnprocessableEntity.new("You are already an approver for this tool")
      end

      CheckoutApproverRequest.create!(member: member, tool: tool, note: note.presence)
    end
    CheckoutNotificationJob.enqueue("approver_volunteer", request.id)
    request
  rescue Mongo::Error::OperationFailure
    raise Error::UnprocessableEntity.new("A volunteer request is already open for this tool")
  end

  def self.approve!(request:, actor:, note: nil)
    return ToolGroupVolunteering.decide!(request: request, actor: actor, approve: true, note: note) if request.tool_group
    approver = CheckoutMutationLock.with(member_id: request.member_id, tool_id: request.tool_id) do
      request.reload
      authorize_decision!(request, actor)
      volunteer = Member.find_by(id: request.member_id)
      raise Error::UnprocessableEntity.new("The volunteer's membership is no longer eligible") unless
        volunteer&.valid_for_checkout_request?
      raise Error::UnprocessableEntity.new("The volunteer no longer has an active checkout") unless
        ToolCheckout.where(member_id: request.member_id, tool_id: request.tool_id, revoked_at: nil).exists?

      record = CheckoutApproverMutationLock.with(member_id: request.member_id) do
        current = CheckoutApprover.find_or_initialize_by(member_id: request.member_id)
        already_assigned = Array(current.tool_ids).map(&:to_s).include?(request.tool_id.to_s)
        if current.new_record?
          current.tool_ids = [request.tool_id.to_s]
          current.save!
        else
          current.add_to_set(tool_ids: request.tool_id.to_s)
        end
        begin
          request.update!(status: "approved", decision_note: note.presence, decided_at: Time.current)
        rescue
          unless already_assigned
            current.pull(tool_ids: request.tool_id.to_s)
            current.destroy! if current.tool_ids.empty? && Array(current.shop_ids).empty?
          end
          raise
        end
        current
      end
      record
    end
    CheckoutNotificationJob.enqueue("approver_volunteer_decision", request.id)
    approver
  end

  def self.decline!(request:, actor:, note: nil)
    return ToolGroupVolunteering.decide!(request: request, actor: actor, approve: false, note: note) if request.tool_group
    CheckoutMutationLock.with(member_id: request.member_id, tool_id: request.tool_id) do
      request.reload
      authorize_decision!(request, actor)
      request.update!(status: "declined", decision_note: note.presence, decided_at: Time.current)
    end
    CheckoutNotificationJob.enqueue("approver_volunteer_decision", request.id)
    request
  end

  def self.revoke_for!(member_id:, tool_id:, approver_lock_held: false)
    CheckoutApproverRequest.where(member_id: member_id, :tool_group_id.in => ToolGroup.where(included_tool_ids: tool_id.to_s).pluck(:id), status: 'open').update_all(status: 'revoked')
    CheckoutApproverRequest.where(member_id: member_id, tool_id: tool_id, status: "open").update_all(status: "revoked")
    mutation = -> do
      approver = CheckoutApprover.find_by(member_id: member_id)
      next unless approver
      approver.pull(tool_ids: tool_id.to_s)
      approver.pull(group_granted_tool_ids: tool_id.to_s)
      ToolGroup.where(included_tool_ids: tool_id.to_s).each do |group|
        approver.pull(tool_group_ids: group.id.to_s)
      end
      approver.destroy! if approver.tool_ids.empty? && Array(approver.shop_ids).empty?
    end
    if approver_lock_held
      mutation.call
    else
      CheckoutApproverMutationLock.with(member_id: member_id, &mutation)
    end
  end

  def self.deliver_request_notifications(request)
    Member.where(:role.in => %w[resource_manager admin board_member],
      :resource_manager_shop_ids.in => [request.target.shop_id.to_s]).each do |manager|
      slack_id = SlackUser.find_by(member_id: manager.id)&.slack_id
      next if slack_id.blank? || manager.direct_notifications_suppressed?
      Service::SlackConnector.send_slack_message(
        "*#{request.member.fullname}* volunteered to approve checkouts for *#{request.target.name}* in *#{request.target.shop.name}*.\n" \
        "Checked out: #{checkout_date(request)}\nJoined makerspace: #{member_join_date(request.member)}" \
        "#{request.note.present? ? "\nNote: #{request.note}" : ""}\n" \
        "Open `/checkout` and choose View open requests to review it.", slack_id)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: "notify checkout volunteer RM", request_id: request.id.to_s })
    end
  end

  def self.authorize_decision!(request, actor)
    raise Error::Forbidden.new("Only a resource manager for this shop can decide this request") unless
      reviewer?(actor, request.target.shop_id)
    raise Error::UnprocessableEntity.new("This volunteer request is no longer open") unless request.open?
  end

  def self.deliver_decision_notification(request)
    slack_id = SlackUser.find_by(member_id: request.member_id)&.slack_id
    return if slack_id.blank? || request.member.direct_notifications_suppressed?
    status = request.status == "approved" ? "approved" : "declined"
    message = "Your request to approve checkouts for *#{request.target.name}* in *#{request.target.shop.name}* was *#{status}*."
    message += "\nRM note: #{request.decision_note}" if request.decision_note.present?
    Service::SlackConnector.send_slack_message(message, slack_id)
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "notify checkout volunteer", request_id: request.id.to_s })
  end

  def self.checkout_date(request)
    request.checkout_completed_on
  end

  def self.member_join_date(member)
    value = member.startDate
    value.respond_to?(:to_date) ? value.to_date.iso8601 : value.to_s.presence || "Unknown"
  end
  def self.reviewer?(member, shop_id)
    member&.role.in?(%w[resource_manager admin board_member]) &&
      Array(member.resource_manager_shop_ids).map(&:to_s).include?(shop_id.to_s)
  end
  private_class_method :authorize_decision!, :checkout_date, :member_join_date
end
