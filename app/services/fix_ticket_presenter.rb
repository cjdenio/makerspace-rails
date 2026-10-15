class FixTicketPresenter
  # Assignment deltas and reporter attribution together identify a self-unassigning
  # reporter. Use the same neutral representation for every assignment event,
  # including historical events and queued deliveries. Current assignees stay visible.
  def self.event_actor(event, ticket, context: nil)
    if event.note.present? && event.note_role == 'assignee'
      return context ? context.member_name(event.actor_id) : Member.where(id: event.actor_id).first&.fullname || 'Former member'
    end
    event.kind == 'assigned' ? 'Member' : member_label(event.actor_id, ticket, context: context)
  end
  def self.event_changes(event, policy: nil, context: nil)
    changes = event.kind == 'assigned' ? event.field_changes.except('assignees') : event.field_changes.dup
    if policy && context
      %w[shop_id tool_id].each do |key|
        next unless changes.key?(key)
        changes[key] = Array(changes[key]).map do |id|
          if key == 'shop_id'
            id if policy.catalog_shop_visible?(context.shop_by_id(id))
          else
            tool = context.tool_by_id(id)
            id if policy.catalog_tool_visible?(tool, context.shop_by_id(tool&.shop_id))
          end
        end
      end
    end
    changes
  end
  def self.member_label(id, ticket, context: nil)
    id.to_s == ticket.reporter_id.to_s && !ticket.show_identity ? 'Reporter' : (context ? context.member_name(id) : Member.where(id: id).first&.fullname || 'Former member')
  end
  def self.ticket(ticket, member, detail: false, context: nil)
    policy = FixTicketPolicy.new(member, ticket, context: context)
    raise Error::NotFound.new unless policy.read?
    unless context
      events = detail ? FixTicketEvent.where(ticket_id: ticket.id).order_by(revision: :asc).to_a : []
      context = FixTicketContext.new([ticket], policy, events: events)
      policy = FixTicketPolicy.new(member, ticket, context: context)
    end
    shop, tool = context.shop(ticket), context.tool(ticket)
    visible_shop = policy.catalog_shop_visible?(shop)
    visible_tool = policy.catalog_tool_visible?(tool, shop)
    result = { id: ticket.id.to_s, reference: ticket.id.to_s, title: ticket.title, description: ticket.description,
      category: ticket.category, status: ticket.status, confirmation: ticket.confirmation,
      priority: ticket.priority, submittedPriority: ticket.submitted_priority, shopId: visible_shop ? ticket.shop_id&.to_s : nil,
      shopName: visible_shop ? shop&.name : nil, toolId: visible_tool ? ticket.tool_id&.to_s : nil, toolName: visible_tool ? tool&.name : nil,
      toolHidden: !!visible_tool && !!tool&.disabled, outOfService: !!visible_tool && !!tool&.out_of_service, uncataloguedTool: ticket.uncatalogued_tool,
      publicReadOnly: ticket.public_read_only, iBrokeIt: ticket.i_broke_it, iCanFixIt: ticket.i_can_fix_it,
      assignees: ticket.assignee_ids.map { |id| { id: id.to_s, name: context.member_name(id) } },
      announceToSlack: ticket.announce_to_slack, announcementNote: ticket.announcement_note,
      bountyId: ticket.bounty_id&.to_s, bountyUrl: ticket.bounty_id ? "/volunteer/tasks/#{ticket.bounty_id}" : nil,
      rewardStatus: context.reward(ticket)&.status,
      revision: ticket.revision, createdAt: ticket.created_at, updatedAt: ticket.updated_at,
      capabilities: policy.capabilities }
    result[:closedBy] = if !ticket.active? && ticket.closed_by_id && ticket.closed_by_id != ticket.reporter_id
      { id: ticket.closed_by_id.to_s, name: context.member_name(ticket.closed_by_id) }
    end
    result[:reporter] = { id: ticket.reporter_id.to_s, name: context.member_name(ticket.reporter_id) } if ticket.show_identity
    if detail
      result[:events] = context.events.map do |event|
        { id: event.id.to_s, kind: event.kind, note: event.note, changes: event_changes(event, policy: policy, context: context),
          actor: event_actor(event, ticket, context: context), createdAt: event.created_at }
      end
      result[:deliveryFailed] = !!policy.staff? && context.events.any? { |event| !event.delivery_error.nil? }
    end
    result
  end
end
