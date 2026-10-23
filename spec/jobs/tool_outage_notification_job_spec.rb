require "rails_helper"

RSpec.describe ToolOutageNotificationJob do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, name: "Bandsaw") }
  let(:member) { create(:member, :current) }
  let(:reservation) { create(:reservation, member: member, shop: shop, reservation_scope: "tools", tool_ids: [tool.id.to_s]) }

  before { allow(Service::SlackConnector).to receive(:send_slack_message) }

  it "DMs the reservation holder when they have a linked Slack account" do
    SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)

    described_class.perform_now(tool.id.to_s, [reservation.id])

    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including("Bandsaw", "out of service"), "U123")
  end

  it "skips a member with no linked Slack account" do
    described_class.perform_now(tool.id.to_s, [reservation.id])

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "skips a member with direct notifications suppressed" do
    SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
    member.update!(status: "suspended")

    described_class.perform_now(tool.id.to_s, [reservation.id])

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "continues notifying remaining reservations after one fails" do
    other_member = create(:member, :current)
    other_reservation = create(:reservation, member: other_member, shop: shop, reservation_scope: "tools", tool_ids: [tool.id.to_s])
    SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
    SlackUser.create!(member: other_member, slack_id: "U456", slack_email: other_member.email)
    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, "U123").and_raise(StandardError, "boom")

    expect(Service::ErrorReporter).to receive(:notify).with("Tool outage reservation notification failed", anything)

    described_class.perform_now(tool.id.to_s, [reservation.id, other_reservation.id])

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, "U456")
  end
end
