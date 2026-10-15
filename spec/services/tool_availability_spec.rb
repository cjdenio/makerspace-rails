require 'rails_helper'
RSpec.describe ToolAvailabilityService do
  before do
    expect(Ticket).not_to receive(:pull)
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'refreshes both overlapping canvas dates on outage and restoration without cancelling bookings' do
    travel_to ReservationService::ZONE.local(2026, 9, 16, 12) do
      tool = create(:tool, shop: create(:shop))
      actor = build(:member, :admin, :current)
      booking = create(:reservation, shop: tool.shop, reservation_scope: 'tools', tool_ids: [tool.id.to_s],
        start_at: ReservationService::ZONE.local(2026, 9, 16, 23), end_at: ReservationService::ZONE.local(2026, 9, 17, 1))
      expect(ReservationSlackCanvasSyncJob).to receive(:perform_later).with(tool.shop_id.to_s, %w[2026-09-16 2026-09-17]).twice
      [true, false].each { |value| described_class.set!(tool: tool, actor: actor, value: value) }
      expect(booking.reload.status).not_to eq('cancelled')
    end
  end
  it 'does not allocate ticket numbers for rejected outages' do
    tool = create(:tool, shop: create(:shop))
    expect { described_class.set!(tool: tool, actor: build(:member, :current), value: true) }.to raise_error(Error::Forbidden)
    expect { described_class.set!(tool: tool, actor: build(:member, :admin, :current), value: 'true') }.to raise_error(Error::UnprocessableEntity)
    expect(tool.reload.out_of_service).to be(false)
  end
  it 'audits actual availability transitions only' do
    tool = create(:tool, shop: create(:shop))
    actor = build(:member, :admin, :current)
    expect(Service::AuditLogger).to receive(:log).with(hash_including(actor: actor, resource_id: tool.id, field_changes: { 'out_of_service' => [false, true] })).once
    2.times { described_class.set!(tool: tool, actor: actor, value: true) }
  end
  it 'does not couple Hidden and out of service, including restoration' do
    admin = build(:member, :admin, :current)
    shop = create(:shop)
    tool = create(:tool, shop: shop, disabled: true)
    described_class.set!(tool: tool, actor: admin, value: true)
    expect(tool.reload.disabled).to be(true)
    expect(tool.out_of_service).to be(true)
    described_class.set!(tool: tool, actor: admin, value: false)
    expect(tool.reload.disabled).to be(true)
    tool.set(disabled: false, out_of_service: true)
    projection = PublicCatalog.tool_fields(*PublicCatalog.tool(tool.id))
    expect(projection[:out_of_service]).to be(true)
    expect(projection.keys).not_to include(:ticket_id, :reporter_id)
  end
  it 'rejects unavailable tools across reservation sources and preserves existing bookings' do
    person = create(:member, :current)
    shop = create(:shop, reservable: true, max_reservation_duration_hours: 24)
    tool = create(:tool, shop: shop, reservable: true, out_of_service: true)
    create(:tool_checkout, member: person, tool: tool)
    start_at = 2.days.from_now.change(hour: 10, min: 0, sec: 0)
    attrs = { title: 'Repair test', shop_id: shop.id.to_s, reservation_scope: 'tools', tool_ids: [tool.id.to_s], start_at: start_at.iso8601, end_at: (start_at + 1.hour).iso8601 }
    preview = ReservationService.preview(member: person, attributes: attrs)
    expect(preview[:errors]).to include('A selected tool is out of service and cannot be reserved')
    %w[portal slack admin].each do |source|
      expect { ReservationService.create!(member: person, attributes: attrs, source: source) }.to raise_error(Error::UnprocessableEntity)
    end
    existing = create(:reservation, member: person, shop: shop, reservation_scope: 'tools', tool_ids: [tool.id.to_s], start_at: start_at, end_at: start_at + 1.hour)
    expect { ReservationService.update!(reservation: existing, attributes: { start_at: (start_at + 1.hour).iso8601, end_at: (start_at + 2.hours).iso8601 }) }.to raise_error(Error::UnprocessableEntity)
    expect(existing.reload.start_at).to eq(start_at)
    expect(existing.status).not_to eq('cancelled')
  end

end
