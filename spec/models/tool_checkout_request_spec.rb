require "rails_helper"

RSpec.describe ToolCheckoutRequest do
  describe "declined status" do
    let(:tool) { create(:tool) }
    let(:member) { create(:member, :current) }

    it "requires a reason of at most 255 characters" do
      request = ToolCheckoutRequest.create!(member: member, tool: tool)

      expect(request.update(status: "declined")).to be(false)
      expect(request.errors[:decision_reason]).to be_present
      expect(request.update(status: "declined", decision_reason: "x" * 256)).to be(false)
      expect(request.update(status: "declined", decision_reason: "Not yet")).to be(true)
      expect(request).to be_declined
      expect(request).not_to be_open
    end

    it "DMs the requester the decision and reason, and skips members who cannot receive DMs" do
      SlackUser.create!(member: member, slack_id: "UREQ", slack_email: member.email)
      request = ToolCheckoutRequest.create!(member: member, tool: tool)
      request.update!(status: "declined", decided_by_id: create(:member).id, decision_reason: "Needs the class first")
      allow(Service::SlackConnector).to receive(:send_slack_message)

      request.notify_declined

      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(include(tool.name, "was declined", "Reason: Needs the class first"), "UREQ")
      member.update!(status: "suspended")
      request.notify_declined
      expect(Service::SlackConnector).to have_received(:send_slack_message).once
    end

    it "only sends the decline DM for a declined request" do
      SlackUser.create!(member: member, slack_id: "UREQ", slack_email: member.email)
      request = ToolCheckoutRequest.create!(member: member, tool: tool)
      expect(Service::SlackConnector).not_to receive(:send_slack_message)

      request.notify_declined
    end
  end

  describe "#notify_requestor" do
    let(:member) { create(:member, :current, status: "suspended") }
    let(:request) { ToolCheckoutRequest.create!(member: member, tool: create(:tool)) }

    before do
      SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
    end

    it "does not directly notify a member whose notifications are suppressed" do
      expect(Service::SlackConnector).not_to receive(:send_slack_message)

      request.notify_requestor
    end
  end
end
