module FixTicketBounty
  extend ActiveSupport::Concern
  def eligible_for?(member)
    return super unless ticket_id
    ticket = FixTicket.where(id: ticket_id).first
    !!(member&.fully_active_unexpired? && ticket&.active? && ticket.reporter_id != member.id && missing_prerequisite_tool_ids(member).empty?)
  end
  def claim!(member)
    return super unless ticket_id
    raise Error::Forbidden.new unless member.fully_active_unexpired?
    ticket = FixTicket.find(ticket_id)
    result = nil
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      ticket.reload
      raise Error::Forbidden.new unless ticket.active?
      raise Error::Forbidden.new('The reporter cannot claim this repair bounty') if ticket.reporter_id == member.id
      raise Error::Forbidden.new('Required tool checkouts are missing') unless missing_prerequisite_tool_ids(member).empty?
      result = super(member, sync_canvas: false)
      previous = ticket.assignee_ids
      ticket.bounty_assignee_ids = (ticket.bounty_assignee_ids + [member.id]).uniq
      ticket.assignee_ids = (ticket.manual_assignee_ids + ticket.bounty_assignee_ids).uniq
      ticket.save!
      FixTicketService.assignment_event!(ticket, member, previous)
    end
    FixTicketService.enqueue(ticket)
    enqueue_volunteer_canvas_sync(struck_task_id: id)
    result
  end
  def release!(member, reason)
    return super unless ticket_id
    release_ticket_claim(member, reason, :notify_member_task_released) { super(member, reason, notify: false) }
  end
  def reject_pending!(member, reason)
    return super unless ticket_id
    release_ticket_claim(member, reason, :notify_member_task_rejected) { super(member, reason, notify: false) }
  end
  def cancel!
    return super unless ticket_id
    ticket = FixTicket.find(ticket_id)
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      if %w[claimed pending].include?(status)
        raise Error::Forbidden.new('Release or reject the linked bounty claim before cancelling it')
      end
      super
    end
  end
  private
  def release_ticket_claim(actor, reason, notification)
    ticket = FixTicket.find(ticket_id)
    former = nil
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      former = claimed_by_id
      yield
      ticket.reload
      previous = ticket.assignee_ids
      ticket.bounty_assignee_ids -= [former]
      ticket.assignee_ids = (ticket.manual_assignee_ids + ticket.bounty_assignee_ids).uniq
      ticket.save!
      update!(status: 'cancelled') unless ticket.active?
      FixTicketService.assignment_event!(ticket, actor, previous)
    end
    Service::VolunteerApprovalReminder.sync_closed!(self)
    FixTicketService.enqueue(ticket)
    enqueue_volunteer_canvas_sync
    send(notification, former, reason)
    self
  end
end
