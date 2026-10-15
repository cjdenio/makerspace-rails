class FixTicketPolicy
  attr_reader :member, :ticket
  def initialize(member, ticket = nil, context: nil)
    @member, @ticket, @context = member, ticket, context
  end
  def global? = member && %w[admin board_member].include?(member.role)
  def current? = !!member&.fully_active_unexpired?
  def catalog_shop_visible?(shop)
    shop && (global? || member&.manages_shop?(shop.id) || !shop.disabled?)
  end
  def catalog_tool_visible?(tool, shop)
    tool && catalog_shop_visible?(shop) && (global? || member&.manages_shop?(tool.shop_id) || !tool.disabled?)
  end
  def approver
    return @context.approver if @context
    return @approver if defined?(@approver)
    @approver = member&.valid_for_checkout_request? && CheckoutApprover.where(member_id: member.id).first
  end
  def staff?
    return false unless member && ticket
    # Hidden controls catalog visibility, not an existing approver's repair scope.
    # Resolve the referenced tool without a disabled filter, just as queue scope does.
    global? || member.manages_shop?(ticket.shop_id) ||
      (approver && (tool ? approver.can_approve_tool?(tool) : approver.can_approve_for_shop?(ticket.shop_id)))
  end
  def reporter? = member && ticket && ticket.reporter_id == member.id
  def assigned? = member && ticket && ticket.assignee_ids.map(&:to_s).include?(member.id.to_s)
  def read? = !!(staff? || reporter? || assigned? || (current? && ticket&.public_read_only))
  def note? = !!(staff? || reporter? || assigned?)
  def change_status? = !!(staff? || assigned?)
  def bounty? = !!(global? || (member && ticket && member.manages_shop?(ticket.shop_id)))
  def tool = @context ? @context.tool(ticket) : ticket.tool
  def public_locked?
    bounty = @context ? @context.bounty(ticket) : ticket.bounty
    bounty && %w[available claimed pending].include?(bounty.status)
  end
  def bounty_replaceable?
    ticket.bounty_id.nil? || (@context ? @context.bounty(ticket) : ticket.bounty)&.status == 'cancelled'
  end
  def reviewable_reward?
    return false unless ticket.status == 'resolved'
    reward = @context ? @context.reward(ticket) : VolunteerCredit.where(id: ticket.reward_id).first
    reward && reward.status == 'pending' && reward.issued_by_id != member.id
  end
  def capabilities
    { requiresNoteRole: !!(reporter? && assigned?), canRead: read?, canAddNote: note?, canChangeStatus: change_status?, canManage: !!staff?,
      canManageVisibility: !!staff? && !public_locked?, publicLocked: !!public_locked?,
      canWithdraw: !!reporter? && ticket.active?, canUnassign: !!assigned?, canCreateBounty: bounty? && !reporter? && ticket.active? && bounty_replaceable?,
      canNominateReward: bounty? && !reporter? && ticket.reward_id.nil? && (ticket.active? || ticket.status == 'resolved'), canReviewReward: bounty? && ticket.reward_id.present? && !reporter? && !!reviewable_reward?, canReveal: member&.role == 'admin' }
  end
  def scope(mode = 'all')
    raise Error::Forbidden.new unless member
    return FixTicket.where(reporter_id: member.id) if mode == 'mine'
    return FixTicket.where(assignee_ids: member.id) if mode == 'assigned'
    return current? ? FixTicket.where(public_read_only: true) : FixTicket.none if mode == 'public'
    return FixTicket.all if global?
    shops = member.role == 'resource_manager' ? Array(member.resource_manager_shop_ids) : []
    rules = [{ :shop_id.in => shops }]
    if approver
      rules << { :shop_id.in => Array(approver.shop_ids) }
      rules << { :tool_id.in => Array(approver.tool_ids) }
    end
    unless mode == 'queue'
      rules += [{ reporter_id: member.id }, { assignee_ids: member.id }]
      rules << { public_read_only: true } if current?
    end
    FixTicket.any_of(*rules)
  end
end
