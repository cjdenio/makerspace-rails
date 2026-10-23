require "rails_helper"

RSpec.describe CheckoutNotificationJob do
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }

  before { allow(Service::ErrorReporter).to receive(:notify) }

  it "delivers approval side effects in order and keeps audit after a DM failure" do
    actor = create(:member, :current, :admin)
    checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
      defer_users_channel_invitation: true)
    allow(ToolCheckout).to receive(:find_by).with(id: checkout.id.to_s).and_return(checkout)
    expect(checkout).to receive(:invite_member_to_users_channel).ordered
    expect(checkout).to receive(:send_checkout_slack_notification).ordered.and_raise(StandardError)
    expect(checkout).to receive(:announce_checkout_success).ordered
    expect(Service::AuditLogger).to receive(:log).with(hash_including(resource_id: checkout.id)).ordered
    described_class.perform_now("approval", checkout.id.to_s)
    expect(checkout.reload).to be_persisted
    expect(Service::ErrorReporter).to have_received(:notify)
  end

  it "announces an open request and suppresses an obsolete queued announcement" do
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(ToolCheckoutRequest).to receive(:find_by).and_return(row)
    expect(row).to receive(:announce_request).once
    described_class.perform_now("request", row.id.to_s)
    row.update!(status: "deleted")
    described_class.perform_now("request", row.id.to_s)
    expect(row).to receive(:remove_announcement)
    described_class.perform_now("cancellation", row.id.to_s)
  end

  it "tells the requester about a decline and updates the channel announcement" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [tool.shop_id.to_s])
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    row.update!(status: "declined", decided_by_id: manager.id, decided_at: Time.current, decision_reason: "Not yet")
    allow(ToolCheckoutRequest).to receive(:find_by).and_return(row)
    expect(row).to receive(:notify_declined).ordered
    expect(row).to receive(:refresh_declined_announcement).ordered

    described_class.perform_now("decline", row.id.to_s)
  end

  it "ignores a queued decline for a request that is not declined" do
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(ToolCheckoutRequest).to receive(:find_by).and_return(row)
    expect(row).not_to receive(:notify_declined)

    described_class.perform_now("decline", row.id.to_s)
  end

  it "reconciles cancellation that finishes while the request announcement is in flight" do
    tool.update!(announce: true, announce_channel: "requests")
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(Service::SlackConnector).to receive(:update_slack_message)
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      other_worker = ToolCheckoutRequest.find(row.id)
      other_worker.update!(status: "deleted")
      described_class.perform_now("cancellation", row.id.to_s)
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
      double(ts: "request-ts")
    end

    described_class.perform_now("request", row.id.to_s)

    expect(row.reload.status).to eq("deleted")
    expect(row.message_id).to eq("request-ts")
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with(tool.announce_channel, "request-ts", include("cancelled their checkout request"))
  end

  it "retains the success announcement and deletes the late request post" do
    tool.update!(announce: true, announce_channel: "requests")
    actor = create(:member, :current, :admin)
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(Service::SlackConnector).to receive(:update_slack_message)
    allow(Service::SlackConnector).to receive(:delete_slack_message)
    allow(Service::SlackConnector).to receive(:send_slack_message) do |message, _channel|
      if message.include?("requested checkout")
        checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
          defer_users_channel_invitation: true)
        checkout.announce_checkout_success
        expect(row.reload.status).to eq("closed")
        expect(row.message_id).to eq("approval-ts")
        double(ts: "request-ts")
      else
        double(ts: "approval-ts")
      end
    end

    described_class.perform_now("request", row.id.to_s)

    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with(tool.announce_channel, "approval-ts", include("has been checked out"))
    expect(Service::SlackConnector).to have_received(:delete_slack_message).with(tool.announce_channel, "request-ts").once
    expect(Service::SlackConnector).not_to have_received(:update_slack_message).with(anything, "request-ts", anything)
    expect(row.reload).to have_attributes(status: "closed", message_id: "approval-ts")
  end

  it "retains the request timestamp when it arrives during a standalone success send" do
    tool.update!(announce: true, announce_channel: "requests")
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: create(:member, :current, :admin),
      defer_users_channel_invitation: true)
    allow(Service::SlackConnector).to receive(:update_slack_message)
    allow(Service::SlackConnector).to receive(:delete_slack_message)
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      # The other worker finishes its in-flight request send while this worker
      # is waiting for Slack to return the success post's timestamp.
      ToolCheckoutRequest.find(row.id).register_announcement("request-ts")
      double(ts: "approval-ts")
    end

    checkout.announce_checkout_success

    expect(row.reload.message_id).to eq("request-ts")
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with(tool.announce_channel, "request-ts", include("has been checked out"))
    expect(Service::SlackConnector).to have_received(:delete_slack_message)
      .with(tool.announce_channel, "approval-ts").once
  end

  it "ignores records deleted before delivery" do
    expect { described_class.perform_now("approval", BSON::ObjectId.new.to_s) }.not_to raise_error
    expect { described_class.perform_now("request", BSON::ObjectId.new.to_s) }.not_to raise_error
  end

  it "delivers volunteer request and decision DMs outside the interaction" do
    create(:tool_checkout, member: member, tool: tool)
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    allow(CheckoutApproverVolunteering).to receive(:deliver_request_notifications)
    allow(CheckoutApproverVolunteering).to receive(:deliver_decision_notification)

    described_class.perform_now("approver_volunteer", request.id.to_s)
    expect(CheckoutApproverVolunteering).to have_received(:deliver_request_notifications).with(request)

    request.update!(status: "approved")
    described_class.perform_now("approver_volunteer_decision", request.id.to_s)
    expect(CheckoutApproverVolunteering).to have_received(:deliver_decision_notification).with(request)
  end

  it "still audits a checkout revoked before delivery without inviting or announcing it" do
    checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: create(:member, :current, :admin),
      revoked_at: Time.current, defer_users_channel_invitation: true)
    allow(ToolCheckout).to receive(:find_by).and_return(checkout)
    expect(checkout).not_to receive(:invite_member_to_users_channel)
    expect(checkout).not_to receive(:send_checkout_slack_notification)
    expect(checkout).not_to receive(:announce_checkout_success)
    expect(Service::AuditLogger).to receive(:log).with(hash_including(resource_id: checkout.id))
    described_class.perform_now("approval", checkout.id.to_s)
  end

  it "reports an aborted enqueue without raising" do
    allow(described_class).to receive(:perform_later).and_return(false)
    expect { described_class.enqueue("request", BSON::ObjectId.new) }.not_to raise_error
    expect(Service::ErrorReporter).to have_received(:notify).with("Checkout notification failed", context: { error_class: "RuntimeError" })
  end
end
