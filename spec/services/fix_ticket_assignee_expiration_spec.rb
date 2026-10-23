require "rails_helper"

RSpec.describe Service::FixTicketAssigneeExpiration do
  let(:active_member) { create(:member, :current) }
  let(:expired_member) { create(:member, :expired) }

  describe ".run!" do
    it "unassigns an expired assignee and reverts to open when they were the only one" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id],
        manual_assignee_ids: [expired_member.id])

      described_class.run!
      ticket.reload

      expect(ticket.assignee_ids).to be_empty
      expect(ticket.manual_assignee_ids).to be_empty
      expect(ticket.status).to eq("open")
    end

    it "keeps the ticket's status when another active assignee remains" do
      ticket = create(:fix_ticket, status: "in_progress",
        assignee_ids: [expired_member.id, active_member.id],
        manual_assignee_ids: [expired_member.id, active_member.id])

      described_class.run!
      ticket.reload

      expect(ticket.assignee_ids).to eq([active_member.id])
      expect(ticket.manual_assignee_ids).to eq([active_member.id])
      expect(ticket.status).to eq("in_progress")
    end

    it "leaves tickets with only active assignees untouched" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [active_member.id])

      expect { described_class.run! }.not_to change { ticket.reload.attributes }
    end

    it "ignores terminal tickets even with an expired assignee" do
      ticket = create(:fix_ticket, status: "resolved", assignee_ids: [expired_member.id])

      expect { described_class.run! }.not_to change { ticket.reload.attributes }
    end

    it "records an audit log entry for the change" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id])

      described_class.run!

      log = AuditLog.where(resource_type: "FixTicket", event_type: "fix_ticket_assignee_expired").first
      expect(log).to be_present
      expect(log.field_changes["status"]).to eq(["in_progress", "open"])
    end

    it "returns the number of tickets it changed" do
      create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id])
      create(:fix_ticket, status: "in_progress", assignee_ids: [active_member.id])

      expect(described_class.run!).to eq(1)
    end
  end
end
