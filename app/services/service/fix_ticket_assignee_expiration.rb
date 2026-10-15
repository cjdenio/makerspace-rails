module Service
  # An assignee whose membership expires can no longer act on a ticket (log
  # in, add notes, change status). Rather than let it sit assigned to someone
  # who can't touch it, drop them as an assignee, and if that was the last
  # one, kick the ticket back to Open so it re-enters the general queue.
  class FixTicketAssigneeExpiration
    def self.run!
      processed = 0
      FixTicket.where(:status.in => FixTicket::ACTIVE, :assignee_ids.ne => []).each do |ticket|
        expired_ids = Member.where(:id.in => ticket.assignee_ids).reject(&:active_unexpired?).map(&:id)
        next if expired_ids.empty?

        before_assignee_ids = ticket.assignee_ids.dup
        before_status = ticket.status
        ticket.assignee_ids -= expired_ids
        ticket.manual_assignee_ids -= expired_ids
        ticket.bounty_assignee_ids -= expired_ids
        ticket.status = "open" if ticket.assignee_ids.empty?
        ticket.save!

        field_changes = { "assignee_ids" => [before_assignee_ids, ticket.assignee_ids] }
        field_changes["status"] = [before_status, ticket.status] if before_status != ticket.status
        ::Service::AuditLogger.log(
          log_type: "portal", event_type: "fix_ticket_assignee_expired",
          resource_type: "FixTicket", resource_id: ticket.id,
          field_changes: field_changes,
          message_details: "removed expired assignee(s): #{expired_ids.map(&:to_s).join(', ')}"
        )
        processed += 1
      end
      processed
    end
  end
end
