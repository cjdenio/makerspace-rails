require 'rails_helper'

RSpec.describe CheckoutApprover do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  before do
    ToolCheckout.create!(member: member, tool: tool, revoked_at: Time.current, defer_users_channel_invitation: true)
  end
  it 'rejects a new group assignment without expanding revoked grants' do
    record = described_class.new(member: member, tool_group_ids: [group.id.to_s])
    expect(record.save).to eq(false)
    expect(record.errors[:tool_group_ids]).to include('cannot include a group with a revoked checkout')
    expect(record.tool_ids).to be_empty
    expect(record.group_granted_tool_ids).to be_empty
  end
  it 'rejects reassignment and preserves unrelated existing authority' do
    other = create(:tool, shop: shop)
    record = described_class.create!(member: member, tool_ids: [other.id.to_s])
    expect(record.update(tool_group_ids: [group.id.to_s])).to eq(false)
    expect(record.reload.tool_group_ids).to be_empty
    expect(record.tool_ids).to eq([other.id.to_s])
    expect(record.can_approve_group?(group)).to eq(false)
  end
end
