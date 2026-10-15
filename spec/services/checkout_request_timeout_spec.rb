require "rails_helper"

RSpec.describe "Checkout request reminders cap and time-out" do
  include ActiveSupport::Testing::TimeHelpers

  let(:shop) { create(:shop, name: "Woodworking") }
  let(:tool) { create(:tool, shop: shop, name: "Laguna Bandsaw") }
  let(:requester) { create(:member, :current, firstname: "Pat", lastname: "Member") }
  let(:requested_at) { Time.zone.local(2026, 10, 1, 9) }
  let!(:request) { ToolCheckoutRequest.create!(member: requester, tool: tool, request_date: requested_at) }
  let(:posted) { double(ts: "111.222", channel: "CRM") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:resource_managers_channel).and_return("resource_managers")
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(posted)
    allow(Service::SlackConnector).to receive(:update_slack_message)
  end

  def remind(days)
    CheckoutRequestReminder.remind!(request, now: requested_at + days.days)
  end

  it "posts at most three reminders" do
    [5, 10, 15, 20, 25, 30].each { |days| remind(days) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, "resource_managers").exactly(3).times
    expect(request.reload.reminders.keys).to contain_exactly("1", "2", "3")
  end

  it "makes the third reminder the last one and says when the request will be declined" do
    remind(5)
    remind(10)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(satisfy { |text| !text.include?("last reminder") }, "resource_managers").twice

    remind(15)

    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including("This is the last reminder", "automatically declined on 2026-10-21",
                               "already done in person"), "resource_managers").once
  end

  describe ".time_out_due!" do
    before { [5, 10, 15].each { |days| remind(days) } }

    it "waits until the last reminder has had its full five days" do
      expect(CheckoutRequestReminder.time_out_due!(request, now: requested_at + 15.days)).to be(false)
      expect(CheckoutRequestReminder.time_out_due!(request, now: requested_at + 19.days)).to be(false)
      expect(request.reload).to be_open
    end

    it "declines the request on the system's authority once the time is up" do
      expect(CheckoutRequestReminder.time_out_due!(request, now: requested_at + 20.days)).to be(true)

      expect(request.reload).to have_attributes(status: "declined", decided_by_id: nil)
      expect(request.decided_at).to be_present
      expect(request.decision_reason).to eq("Automatically declined: timed out with no checkout recorded after 20 days. " \
                                            "Contact the board if you still need this checkout.")
      expect(request).to be_timed_out
      expect(CheckoutNotificationJob).to have_been_enqueued.with("decline", request.id.to_s)
      expect(AuditLog.where(resource_id: request.id, event_type: "tool_checkout_request_timed_out")).to exist
    end

    it "does nothing to a request that was resolved in the meantime" do
      request.update!(status: "closed")

      expect(CheckoutRequestReminder.time_out_due!(request, now: requested_at + 20.days)).to be(false)
      expect(request.reload.status).to eq("closed")
    end

    it "edits the posted reminders to say the request timed out" do
      CheckoutRequestReminder.time_out_due!(request, now: requested_at + 20.days)

      CheckoutRequestReminder.finalize!(request)

      expect(Service::SlackConnector).to have_received(:update_slack_message)
        .with("CRM", "111.222", include("no longer waiting: timed out and was automatically declined."),
              resolved_channel: true).exactly(3).times
    end
  end

  it "never times out a request that has had fewer than three reminders" do
    remind(5)
    remind(10)

    expect(CheckoutRequestReminder.time_out_due!(request, now: requested_at + 60.days)).to be(false)
    expect(request.reload).to be_open
  end

  it "gives a request that is already old when this ships all three reminders first" do
    old_request = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool,
                                              request_date: requested_at - 40.days)

    CheckoutRequestReminder.remind!(old_request, now: requested_at)
    expect(old_request.reload.reminders.size).to eq(1)
    expect(CheckoutRequestReminder.time_out_due!(old_request, now: requested_at)).to be(false)
    expect(old_request.reload).to be_open
  end

  describe "the requester's notifications" do
    before do
      SlackUser.create!(member: requester, slack_id: "UREQ", slack_email: requester.email)
      remind(5)
      remind(10)
      remind(15)
      CheckoutRequestReminder.time_out_due!(request, now: requested_at + 20.days)
    end

    it "DMs the requester that it timed out, with how to reach the board" do
      allow(Service::SlackConnector).to receive(:send_slack_message)

      request.reload.notify_declined

      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_including("Laguna Bandsaw", "automatically declined because it timed out",
                           "within 20 days", "contact the board on Slack or visit an open house",
                           "submit a new request"), "UREQ")
    end

    it "words the channel announcement as a time-out" do
      expect(request.reload.declined_announcement_message)
        .to include("timed out after 20 days and was automatically declined")
    end
  end

  describe "CheckoutRequestReminderJob" do
    it "posts three reminders five days apart and then declines the request" do
      [5, 10, 15].each do |days|
        travel_to(requested_at + days.days + 1.hour) { CheckoutRequestReminderJob.perform_now }
      end
      expect(request.reload).to be_open
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, "resource_managers").exactly(3).times

      travel_to(requested_at + 20.days + 1.hour) { CheckoutRequestReminderJob.perform_now }

      expect(request.reload).to be_timed_out
      # No fourth reminder; the only other post is the audit log entry.
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, "resource_managers").exactly(3).times
    end
  end
end
