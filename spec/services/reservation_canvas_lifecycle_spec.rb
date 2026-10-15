require "rails_helper"

RSpec.describe "Reservation canvas lifecycle" do
  let(:zone) { ReservationService::ZONE }
  let(:member) { create(:member, :current) }
  let(:actor) { create(:member, :current, role: "admin") }
  let(:shop) { create(:shop, reservable: true, max_reservation_duration_hours: 48) }
  let(:start_at) { zone.local(2026, 9, 9, 23) }
  let(:end_at) { zone.local(2026, 9, 10, 1) }
  let(:reservation) do
    create(:reservation, member: member, shop: shop, reservation_scope: "shop", tool_ids: [],
      start_at: start_at, end_at: end_at, status: "pending")
  end

  around do |example|
    travel_to(zone.local(2026, 9, 9, 8)) { example.run }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  %i[approve! deny! cancel!].each do |action|
    it "refreshes today and tomorrow on #{action}" do
      existing = reservation
      manager = actor
      expect {
        ReservationService.public_send(action, reservation: existing, actor: manager)
      }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
        .with(shop.id.to_s, %w[2026-09-09 2026-09-10]).exactly(:once)
    end
  end

  it "refreshes both dates for a title-only edit" do
    existing = reservation
    expect {
      ReservationService.update!(reservation: existing, attributes: { title: "Changed title" })
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
      .with(shop.id.to_s, %w[2026-09-09 2026-09-10]).exactly(:once)
  end

  it "refreshes the old shop and new shop when moving an existing reservation" do
    existing = reservation
    destination = create(:shop, reservable: true, max_reservation_duration_hours: 48)
    expect {
      ReservationService.update!(reservation: existing, actor: actor, attributes: {
        shop_id: destination.id.to_s, start_at: zone.local(2026, 9, 10, 10), end_at: zone.local(2026, 9, 10, 11)
      })
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob).with(shop.id.to_s, %w[2026-09-09 2026-09-10])
      .and have_enqueued_job(ReservationSlackCanvasSyncJob).with(destination.id.to_s, ["2026-09-10"])
  end

  it "removes the old dates when moving beyond tomorrow" do
    existing = reservation
    expect {
      ReservationService.update!(reservation: existing, actor: actor, attributes: {
        start_at: zone.local(2026, 9, 11, 10), end_at: zone.local(2026, 9, 11, 11)
      })
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
      .with(shop.id.to_s, %w[2026-09-09 2026-09-10]).exactly(:once)
  end

  it "refreshes both canvases after confirmed invoice payment activates a reservation" do
    existing = reservation
    invoice = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 10, due_date: start_at - 4.hours, reservation_id: existing.id.to_s)
    existing.update!(status: "unpaid", invoice: invoice.id.to_s, approval_reasons: [])
    expect {
      invoice.submit_for_settlement(nil, nil, "confirmed-payment")
    }.to have_enqueued_job(ReservationInvoiceSyncJob).with(invoice.id.to_s)
    expect {
      ReservationInvoiceSyncJob.perform_now(invoice.id.to_s)
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
      .with(shop.id.to_s, %w[2026-09-09 2026-09-10]).exactly(:once)
    expect(existing.reload.status).to eq("approved")
  end

  it "does not refresh tomorrow for a reservation ending exactly at midnight" do
    existing = reservation
    existing.update!(end_at: zone.local(2026, 9, 10))
    expect {
      ReservationService.deny!(reservation: existing, actor: actor)
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob).with(shop.id.to_s, ["2026-09-09"]).exactly(:once)
  end

  it "does not refresh either canvas for a reservation beyond tomorrow" do
    existing = reservation
    existing.update!(start_at: zone.local(2026, 9, 11, 10), end_at: zone.local(2026, 9, 11, 11))
    expect {
      ReservationService.deny!(reservation: existing, actor: actor)
    }.not_to have_enqueued_job(ReservationSlackCanvasSyncJob)
  end
end
