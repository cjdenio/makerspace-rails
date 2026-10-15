require "rails_helper"

RSpec.describe ReservationFeeNotificationJob do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:reservation) { create(:reservation, member: member, shop: shop, reservation_scope: "shop", tool_ids: [], status: "unpaid") }
  let(:invoice) do
    Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 30, due_date: 1.hour.ago, reservation_id: reservation.id.to_s)
  end

  before do
    reservation.update!(invoice: invoice.id.to_s)
    allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(double(slack_id: "U123"))
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ "ts" => "123.456", "channel" => "D123" })
  end

  it "records the DM timestamp and updates the same message on subsequent changes" do
    described_class.new.perform(reservation.id.to_s)
    expect(reservation.reload.notified_at).to eq("123.456")
    expect(reservation.notified_channel_id).to eq("D123")
    expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "123.456", include("Unpaid: $30.00", "paid before"))
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    described_class.new.perform(reservation.id.to_s)
  end

  it "sends the cancellation warning while leaving the invoice intact" do
    reservation.update!(status: "cancelled")
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include("unpaid reservation has been cancelled", "invoice remains payable"), "U123")
    described_class.new.perform(reservation.id.to_s)
    expect(invoice.reload.settled).to eq(false)
  end

  %w[approved denied].each do |status|
    it "updates the saved DM for a #{status} reservation without an invoice" do
      reservation.update!(invoice: nil, status: status, decision_note: "Manager decision", notified_at: "old.ts", notified_channel_id: "D123")
      expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "old.ts", include("Status: #{status}", "Manager decision", reservation.title))
      expect(Service::SlackConnector).not_to receive(:send_slack_message)
      ReservationDecisionNotificationJob.perform_now(reservation.id.to_s)
    end
  end

  %w[message_not_found channel_not_found cant_update_message].each do |error|
    it "falls back to a new DM and saves its identifiers for #{error}" do
      reservation.update!(notified_at: "old.ts", notified_channel_id: "DOLD")
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(Slack::Web::Api::Errors::SlackError.new(error))
      expect(Service::SlackConnector).to receive(:send_slack_message).with(include(reservation.title), "U123")
      described_class.perform_now(reservation.id.to_s)
      expect(reservation.reload.notified_at).to eq("123.456")
      expect(reservation.notified_channel_id).to eq("D123")
    end
  end

  it "does not send a duplicate DM for other Slack errors" do
    reservation.update!(notified_at: "old.ts")
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(Slack::Web::Api::Errors::SlackError.new("ratelimited"))
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    expect { described_class.new.perform(reservation.id.to_s) }.to raise_error(Slack::Web::Api::Errors::SlackError)
  end

  it "explains approval with payment still outstanding" do
    reservation.update!(decided_at: Time.current, approval_reasons: [])
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include("has been approved", "payment is required", "Unpaid: $30.00"), "U123")
    described_class.perform_now(reservation.id.to_s)
  end

  it "updates the existing DM after payment confirmation" do
    invoice.update!(settled_at: Time.current)
    reservation.update!(status: "approved", notified_at: "old.ts", notified_channel_id: "D123")
    expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "old.ts", include("Status: approved", "Paid: $30.00", "Payment confirmed"))
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    described_class.perform_now(reservation.id.to_s)
  end

  it "reports all unpaid debt, excluding paid invoices and duplicate links" do
    historical = invoice
    difference = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 10, due_date: 1.day.from_now, reservation_id: reservation.id.to_s)
    paid = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 5, due_date: 1.day.from_now, settled_at: Time.current, reservation_id: reservation.id.to_s)
    reservation.update!(invoice: difference.id.to_s, previous_invoice_ids: [historical.id.to_s, historical.id.to_s, paid.id.to_s],
      notified_at: "old.ts", notified_channel_id: "D123")
    expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "old.ts",
      include("Unpaid: $40.00", "2 unpaid invoices", "paid before"))
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    described_class.perform_now(reservation.id.to_s)
  end

  it "reports historical unpaid debt even if the current invoice is paid" do
    historical = invoice
    current = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 10, due_date: 1.day.from_now, settled_at: Time.current, reservation_id: reservation.id.to_s)
    reservation.update!(invoice: current.id.to_s, previous_invoice_ids: [historical.id.to_s])
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include("Unpaid: $30.00", "paid before"), "U123")
    described_class.perform_now(reservation.id.to_s)
  end

  it "reports total payment across all settled invoices" do
    invoice.update!(settled_at: Time.current)
    current = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 10, due_date: 1.day.from_now, settled_at: Time.current, reservation_id: reservation.id.to_s)
    reservation.update!(invoice: current.id.to_s, previous_invoice_ids: [invoice.id.to_s], status: "approved")
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include("Paid: $40.00", "Payment confirmed"), "U123")
    described_class.perform_now(reservation.id.to_s)
  end

  %w[cancelled denied].each do |status|
    it "updates the payment DM for a #{status} reservation after its shop is deleted" do
      reservation.update!(status: status, notified_at: "old.ts", notified_channel_id: "D123",
        fee_snapshot: [{ "resourceId" => shop.id.to_s, "resourceName" => "Original shop", "amount" => 30 }])
      shop.delete
      invoice.update!(settled_at: Time.current)
      allow(REDIS).to receive(:set).and_return(true)
      allow(REDIS).to receive(:eval).and_return(1)
      expect {
        ReservationInvoiceSyncJob.perform_now(invoice.id.to_s)
      }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
      expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "old.ts",
        include("Original shop", "Paid: $30.00", "Payment confirmed", "remains #{status}"))
      expect(Service::SlackConnector).not_to receive(:send_slack_message)
      described_class.perform_now(reservation.id.to_s)
      expect(reservation.reload.status).to eq(status)
    end
  end

  it "uses a readable fallback and sends a DM when no saved shop name exists" do
    reservation.update!(status: "cancelled")
    shop.delete
    invoice.update!(settled_at: Time.current)
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include("Deleted shop", "Payment confirmed"), "U123")
    described_class.perform_now(reservation.id.to_s)
    expect(reservation.reload.notified_at).to eq("123.456")
  end

  %w[cancelled denied].each do |status|
    it "uses saved names for deleted tools while retaining current names for surviving tools (#{status})" do
      removed = create(:tool, shop: shop, name: "Removed tool")
      surviving = create(:tool, shop: shop, name: "Current tool")
      unknown = create(:tool, shop: shop, name: "Unsaved tool")
      unknown_id = unknown.id.to_s
      reservation.update!(reservation_scope: "tools", tool_ids: [removed.id.to_s, surviving.id.to_s, unknown_id],
        status: status, notified_at: "old.ts", notified_channel_id: "D123",
        fee_snapshot: [
          { "resourceId" => removed.id.to_s, "resourceName" => "Saved tool", "amount" => 30 },
          { "resourceId" => surviving.id.to_s, "resourceName" => "Old tool name", "amount" => 0 },
          { "resourceId" => BSON::ObjectId.new.to_s, "resourceName" => "Previously removed selection", "amount" => 0 }
        ])
      removed.delete
      unknown.delete
      invoice.update!(settled_at: Time.current)
      expect(Service::SlackConnector).to receive(:update_slack_message).with("D123", "old.ts",
        include("Saved tool, Current tool, Deleted tool", "Payment confirmed", "remains #{status}"))
      expect(Service::SlackConnector).not_to receive(:send_slack_message)
      described_class.perform_now(reservation.id.to_s)
    end
  end

end
