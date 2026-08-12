class WorkshopSerializer < ActiveModel::Serializer
  attributes :id, :name, :wiki_url, :gdrive_id, :slack_channel,
             :slack_channel_details, :disabled, :reservable,
             :reservations_available, :resource_managers,
             :resource_managers_wiki_url, :upcoming_volunteer_events,
             :volunteer_tasks, :can_add_tool, :can_create_volunteer_task,
             :is_shop_manager, :tools

  def wiki_url
    object.effective_wiki_url
  end

  def resource_managers_wiki_url
    "#{WikiUrlBuilder.base_url}/workshops/resource-managers"
  end

  def slack_channel_details
    channel_details(object.slack_channel)
  end

  def tools
    visible_tools.map do |tool|
      checkout = checkout_for(tool)
      request = checkout_request_for(tool)
      missing_checkout_ids =
        Array(tool.prerequisite_ids).map(&:to_s) - checked_out_tool_ids

      {
        id: tool.id.to_s,
        name: tool.name,
        wikiUrl: tool.effective_wiki_url,
        gdriveId: tool.gdrive_id,
        description: tool.description,
        disabled: tool.disabled?,
        reservable: tool.reservable,
        prerequisiteIds: Array(tool.prerequisite_ids).map(&:to_s),
        prerequisiteNames: tool.prerequisites.map(&:name),
        unmetPrerequisiteIds: missing_checkout_ids,
        unmetPrerequisiteNames: Tool.where(
          :id.in => missing_checkout_ids
        ).map(&:name),
        checkout: checkout && checkout_details(checkout),
        checkoutRequest: request && checkout_request_details(request),
        checkoutRequestable: checkout.nil? && request.nil? &&
          checkout_requestable?(tool) && !tool.disabled?,
        reservationAvailable: tool_reservation_available?(tool),
        usersChannel: checkout&.active? ? tool.users_channel : nil,
        usersChannelDetails: checkout&.active? ?
          channel_details(tool.users_channel) : nil
      }
    end
  end

  def resource_managers
    @resource_managers ||= Member.where(
      role: "resource_manager",
      :resource_manager_shop_ids.in => [object.id.to_s]
    ).order_by(lastname: :asc, firstname: :asc).map do |member|
      slack_user = member.slack_user
      {
        id: member.id.to_s,
        name: member.fullname,
        slackUrl: slack_user &&
          ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
      }
    end
  end

  def upcoming_volunteer_events
    VolunteerEvent.where(
      shop_id: object.id,
      status: "open",
      :event_date.gte => Date.current
    ).order_by(event_date: :asc).filter_map do |event|
      next unless event.eligible_for?(viewer)

      {
        id: event.id.to_s,
        title: event.title,
        description: event.description,
        creditValue: event.credit_value,
        eventDate: event.event_date&.iso8601
      }
    end
  end

  def volunteer_tasks
    tasks = VolunteerTask.claimable.where(
      shop_id: object.id,
      parent_task_id: nil
    ).order_by(task_number: :asc).to_a.filter_map do |task|
      missing_ids = task.missing_prerequisite_tool_ids(viewer)
      missing_tools = Tool.where(:id.in => missing_ids).to_a
      missing_by_id = missing_tools.index_by { |tool| tool.id.to_s }
      hidden_or_missing_prerequisite = missing_ids.any? do |tool_id|
        tool = missing_by_id[tool_id]
        tool.nil? || tool.disabled?
      end

      unless global_privilege?
        next if hidden_or_missing_prerequisite
      end

      eligible = viewer.status == "activeMember" && (
        global_privilege? || missing_ids.empty?
      )
      {
        id: task.id.to_s,
        taskNumber: task.task_number,
        title: task.title,
        description: task.description,
        creditValue: task.credit_value,
        status: task.status,
        prerequisiteToolNames: task.prerequisite_tools.map(&:name),
        missingPrerequisiteToolNames: missing_ids.map do |tool_id|
          missing_by_id[tool_id]&.name || "Unavailable tool"
        end,
        eligible: eligible
      }
    end

    tasks.sort_by { |task| task[:eligible] ? 0 : 1 }
  end

  def reservations_available
    return false unless viewer_can_reserve?
    return false if object.disabled?
    return true if !pending_reservation_restrictions? && object.reservable &&
      reservation_requirements_met?(object.reservation_prerequisite_tool_ids)

    visible_tools.any? { |tool| tool_reservation_available?(tool) }
  end

  def can_add_tool
    global_privilege? || viewer.manages_shop?(object)
  end

  def can_create_volunteer_task
    VolunteerAdministrationAuthorization.allowed?(viewer, object.id)
  end

  def is_shop_manager
    global_privilege? || viewer.manages_shop?(object)
  end

  private

  def viewer
    scope
  end

  def global_privilege?
    viewer.role.in?(%w[admin board_member])
  end

  def visible_tools
    @visible_tools ||= begin
      shop_tools = object.tools.order_by(name: :asc).to_a
      if global_privilege? || viewer.manages_shop?(object)
        shop_tools
      else
        shop_tools.select do |tool|
          !tool.disabled? || checked_out_tool_ids.include?(tool.id.to_s)
        end
      end
    end
  end

  def viewer_can_reserve?
    viewer.role == "board_member" || viewer.status == "pending" ||
      viewer.active_unexpired?
  end

  def tool_reservation_available?(tool)
    viewer_can_reserve? && !object.disabled? && !tool.disabled? &&
      tool.reservable && pending_tool_allowed?(tool) &&
      reservation_requirements_met?(
        tool.effective_reservation_prerequisite_ids,
        pending_tool: tool
      )
  end

  def reservation_requirements_met?(required_ids, pending_tool: nil)
    return true if viewer.role == "board_member"

    required_ids = Array(required_ids).map(&:to_s)
    if pending_reservation_restrictions? && pending_tool&.allow_pending
      required_ids -= [pending_tool.id.to_s]
    end

    (required_ids - checked_out_tool_ids).empty?
  end

  def checkout_requestable?(tool)
    return tool.allow_pending if viewer.status == "pending"

    viewer.status == "activeMember" && viewer.active_unexpired?
  end

  def pending_tool_allowed?(tool)
    !pending_reservation_restrictions? || tool.allow_pending
  end

  def pending_reservation_restrictions?
    viewer.status == "pending" && viewer.role != "board_member"
  end

  def checked_out_tool_ids
    @checked_out_tool_ids ||= ToolCheckout.where(
      member_id: viewer.id,
      revoked_at: nil
    ).pluck(:tool_id).map(&:to_s)
  end

  def checkout_for(tool)
    @checkouts_by_tool ||= ToolCheckout.where(
      member_id: viewer.id,
      :tool_id.in => visible_tools.map(&:id)
    ).order_by(checked_out_at: :desc).to_a.group_by do |checkout|
      checkout.tool_id.to_s
    end.transform_values(&:first)
    @checkouts_by_tool[tool.id.to_s]
  end

  def checkout_request_for(tool)
    @requests_by_tool ||= ToolCheckoutRequest.where(
      member_id: viewer.id,
      status: "open",
      :tool_id.in => visible_tools.map(&:id)
    ).to_a.index_by { |request| request.tool_id.to_s }
    @requests_by_tool[tool.id.to_s]
  end

  def checkout_details(checkout)
    {
      id: checkout.id.to_s,
      active: checkout.active?,
      checkedOutAt: checkout.checked_out_at&.iso8601,
      revokedAt: checkout.revoked_at&.iso8601,
      approvedByName: checkout.approved_by&.fullname
    }
  end

  def checkout_request_details(request)
    {
      id: request.id.to_s,
      note: request.note,
      requestDate: request.request_date&.iso8601,
      status: request.status
    }
  end

  def channel_details(channel_name)
    cached = Service::SlackChannelCache.fetch(channel_name)
    return nil if cached.blank?

    {
      id: cached[:id],
      name: cached[:name],
      topic: cached[:topic],
      purpose: cached[:purpose],
      slackUrl: Service::SlackConnector.slack_channel_url(cached[:id])
    }
  end
end
