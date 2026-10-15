require 'rails_helper'

RSpec.describe ToolGroupVolunteering do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  let(:member) { create(:member, :current) }
  let(:actor) { create(:member, :current, :resource_manager, resource_manager_shop_ids: [shop.id.to_s]) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(CheckoutNotificationJob).to receive(:enqueue)
  end
  it 'requires every current checkout, revalidates at decision and removes authority on revocation' do
    expect { described_class.create!(member: member, group: group) }.to raise_error(Error::UnprocessableEntity)
    checkout = ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true)
    request = described_class.create!(member: member, group: group)
    extra = create(:tool, shop: shop)
    group.update!(included_tool_ids: [tool.id.to_s, extra.id.to_s])
    expect { described_class.decide!(request: request, actor: actor, approve: true) }.to raise_error(Error::UnprocessableEntity)
    ToolCheckout.create!(member: member, tool: extra, defer_users_channel_invitation: true)
    described_class.decide!(request: request, actor: actor, approve: true)
    expect(CheckoutApprover.find_by(member_id: member.id).can_approve_group?(group)).to eq(true)
    checkout.update!(revoked_at: Time.current)
    approver = CheckoutApprover.find_by(member_id: member.id)
    expect(approver.can_approve_group?(group)).to eq(false)
    expect(approver.tool_ids).not_to include(tool.id.to_s)
  end
end
