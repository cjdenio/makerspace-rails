require 'rails_helper'

RSpec.describe ReservationGroupExpansion do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, reservable: false) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s], reservable: true) }
  it 'expands and deduplicates physical tools without changing child settings' do
    result = described_class.call(shop_id: shop.id, reservation_scope: 'tools', tool_ids: [tool.id.to_s], tool_group_ids: [group.id.to_s])
    expect(result[:tool_ids]).to eq([tool.id.to_s])
    expect(result[:group_snapshots].first['name']).to eq('Kit')
    expect(tool.reload.reservable).to eq(false)
  end
  it 'retains membership and name when only other reservation fields change' do
    snapshot = [{ 'id' => group.id.to_s, 'name' => 'Original', 'tool_ids' => [tool.id.to_s] }]
    reservation = Reservation.new(tool_ids: [tool.id.to_s], tool_group_ids: [group.id.to_s], group_snapshots: snapshot)
    group.update!(name: 'Renamed')
    expect(described_class.call({ title: 'Changed' }, reservation)[:group_snapshots]).to eq(snapshot)
    expect(described_class.call({ tool_ids: [tool.id.to_s], title: 'Legacy edit' }, reservation)[:group_snapshots]).to eq(snapshot)
  end
  it 'rejects groups from another shop or archived groups' do
    expect { described_class.call(shop_id: create(:shop).id, reservation_scope: 'tools', tool_group_ids: [group.id.to_s]) }.to raise_error(Error::UnprocessableEntity)
    group.update!(archived: true)
    expect { described_class.call(shop_id: shop.id, reservation_scope: 'tools', tool_group_ids: [group.id.to_s]) }.to raise_error(Error::UnprocessableEntity)
  end
end
