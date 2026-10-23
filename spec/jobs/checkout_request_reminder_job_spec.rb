require "rails_helper"

RSpec.describe CheckoutRequestReminderJob, type: :job do
  let(:tool) { create(:tool) }
  let(:member) { create(:member, :current) }
  let(:posted) { double(ts: "111.222", channel: "CRM") }

  before do
    allow(SystemConfig).to receive(:record_run)
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(posted)
    allow(Service::SlackConnector).to receive(:update_slack_message)
  end

  it "reminds only about open requests that have waited at least five days and records success" do
    old = ToolCheckoutRequest.create!(member: member, tool: tool, request_date: 6.days.ago)
    ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool, request_date: 2.days.ago)
    ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool, request_date: 9.days.ago, status: "deleted")

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(old.reload.reminders.keys).to eq(["1"])
    expect(SystemConfig).to have_received(:record_run).with("checkout_request_reminder", success: true)
  end

  it "edits the reminder of a request that was resolved since it was posted" do
    request = ToolCheckoutRequest.create!(member: member, tool: tool, request_date: 6.days.ago)
    described_class.perform_now
    request.update!(status: "deleted")

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with("CRM", "111.222", include("cancelled by the requester"), resolved_channel: true)
    expect(request.reload.reminder_open).to be(false)
  end

  it "reports one request's failure and continues with the rest" do
    allow(Service::ErrorReporter).to receive(:notify)
    first = ToolCheckoutRequest.create!(member: member, tool: tool, request_date: 7.days.ago)
    second = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool, request_date: 6.days.ago)
    calls = 0
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      calls += 1
      raise "Slack unavailable" if calls == 1
      posted
    end

    described_class.perform_now

    expect(Service::ErrorReporter).to have_received(:notify).once
    sent = [first, second].map { |request| request.reload.reminders.dig("1", "status") }
    expect(sent).to contain_exactly("failed", "sent")
  end

  it "records and reports a failure of the scan itself" do
    error = StandardError.new("Mongo unavailable")
    allow(ToolCheckoutRequest).to receive(:where).and_raise(error)
    allow(Service::ErrorReporter).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run).with("checkout_request_reminder", success: false)
  end
end
