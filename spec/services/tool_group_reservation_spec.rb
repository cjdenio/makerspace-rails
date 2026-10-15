require 'rails_helper'

RSpec.describe 'Tool group reservation policies' do
  let(:shop) { create(:shop, reservable: false) }
  let(:tool) { create(:tool, shop: shop, reservable: false) }
  let(:member) { create(:member, :current) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Original kit', included_tool_ids: [tool.id.to_s], reservable: true) }
  let(:attributes) do
    date = Time.current.in_time_zone(ReservationService::ZONE).to_date + 1
    start_at = ReservationService::ZONE.local(date.year, date.month, date.day, 10)
    { title: 'Group booking', shop_id: shop.id.to_s, reservation_scope: 'tools',
      tool_ids: [], tool_group_ids: [group.id.to_s], start_at: start_at, end_at: start_at + 1.hour }
  end
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter = :test
    create(:tool_checkout, member: member, tool: tool)
  end
  it 'books nonreservable children, deduplicates overlapping groups, and retains snapshots on title edits' do
    overlapping = ToolGroup.create!(shop: shop, name: 'Other kit', included_tool_ids: [tool.id.to_s], reservable: true)
    booking = ReservationService.create!(member: member, attributes: attributes.merge(tool_group_ids: [group.id.to_s, overlapping.id.to_s]))
    expect(booking.tool_ids).to eq([tool.id.to_s])
    other = create(:tool, shop: shop)
    group.update!(name: 'Changed kit', included_tool_ids: [other.id.to_s], archived: true)
    ReservationService.update!(reservation: booking, attributes: { title: 'Renamed booking' })
    expect(booking.reload.tool_ids).to eq([tool.id.to_s])
    expect(booking.group_snapshots.map { |snapshot| snapshot['name'] }).to include('Original kit')
    expect(ReservationCalendarSyncJob).to have_been_enqueued.exactly(2).times
  end
  it 'keeps child capacity, outages, and external prerequisite requirements' do
    ReservationService.create!(member: member, attributes: attributes)
    other = create(:member, :current)
    create(:tool_checkout, member: other, tool: tool)
    expect(ReservationService.preview(member: other, attributes: attributes)[:eligible]).to eq(false)
    tool.update!(out_of_service: true)
    expect(ReservationService.preview(member: member, attributes: attributes)[:eligible]).to eq(false)
    tool.update!(out_of_service: false)
    prerequisite = create(:tool, shop: shop)
    group.update!(prerequisite_ids: [prerequisite.id.to_s])
    preview = ReservationService.preview(member: member, attributes: attributes.merge(start_at: attributes[:start_at] + 2.hours, end_at: attributes[:end_at] + 2.hours))
    expect(preview[:eligible]).to eq(false)
    expect(preview[:missingPrerequisites]).to include(hash_including(name: prerequisite.name))
  end
end
