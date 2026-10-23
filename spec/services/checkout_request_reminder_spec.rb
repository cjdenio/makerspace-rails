require "rails_helper"

RSpec.describe CheckoutRequestReminder do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, name: "Laguna Bandsaw") }
  let(:requester) { create(:member, :current, firstname: "Pat", lastname: "Member") }
  let(:requested_at) { Time.zone.local(2026, 10, 1, 9) }
  let!(:request) { ToolCheckoutRequest.create!(member: requester, tool: tool, request_date: requested_at) }
  let(:posted) { double(ts: "111.222", channel: "CRM") }

  before do
    allow(Service::SlackConnector).to receive(:resource_managers_channel).and_return("resource_managers")
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(posted)
    allow(Service::SlackConnector).to receive(:update_slack_message)
  end

  it "waits until the request has been open for five days" do
    described_class.remind!(request, now: requested_at + 4.days)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "posts the still-waiting reminder to the configured Resource Managers channel" do
    described_class.remind!(request, now: requested_at + 5.days)

    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with("*Pat Member* requested checkout on *Laguna Bandsaw* (#{shop.name}) on 2026-10-01 and is still waiting. "             "If this was already done in person, please record the checkout so this stops.",
            "resource_managers")
    expect(request.reload.reminders.fetch("1")).to include("status" => "sent", "ts" => "111.222", "channel" => "CRM")
    expect(request.reminder_open).to be(true)
  end

  it "posts each reminder only once and then again every five days" do
    described_class.remind!(request, now: requested_at + 5.days)
    described_class.remind!(request, now: requested_at + 6.days)
    described_class.remind!(request, now: requested_at + 9.days)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once

    described_class.remind!(request, now: requested_at + 10.days)
    described_class.remind!(request, now: requested_at + 14.days)
    described_class.remind!(request, now: requested_at + 15.days)

    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(3).times
    expect(request.reload.reminders.keys).to contain_exactly("1", "2", "3")
  end

  it "retries a failed post on the next scan" do
    allow(Service::ErrorReporter).to receive(:notify)
    attempts = 0
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      attempts += 1
      raise "Slack unavailable" if attempts == 1
      posted
    end

    expect { described_class.remind!(request, now: requested_at + 5.days) }.to raise_error("Slack unavailable")
    expect(request.reload.reminders.fetch("1")).to include("status" => "failed")
    described_class.remind!(request, now: requested_at + 5.days + 1.hour)

    expect(request.reload.reminders.fetch("1")).to include("status" => "sent")
  end

  it "does not remind about a request that is no longer open" do
    request.update!(status: "deleted")

    described_class.remind!(request, now: requested_at + 5.days)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  describe ".finalize!" do
    before { described_class.remind!(request, now: requested_at + 5.days) }

    {
      "declined" => "declined",
      "deleted" => "cancelled by the requester",
      "closed" => "approved"
    }.each do |status, outcome|
      it "edits the posted reminder when the request is #{status}" do
        request.update!(status: status, decision_reason: ("Not now" if status == "declined"),
                        decided_by_id: (create(:member).id if status == "declined"))

        described_class.finalize!(request)

        expect(Service::SlackConnector).to have_received(:update_slack_message)
          .with("CRM", "111.222", include("Pat Member", "Laguna Bandsaw", "no longer waiting: #{outcome}."),
                resolved_channel: true)
        expect(request.reload.reminder_open).to be(false)
        expect(request.reminders.fetch("1")).to include("finalized" => true)
      end
    end

    it "leaves an open request's reminder alone" do
      described_class.finalize!(request)

      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end

    it "keeps the reminder pending when the edit fails so the daily job can retry" do
      request.update!(status: "deleted")
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise("Slack unavailable")

      expect { described_class.finalize!(request) }.to raise_error("Slack unavailable")
      expect(request.reload.reminder_open).to be(true)
    end
  end
end
