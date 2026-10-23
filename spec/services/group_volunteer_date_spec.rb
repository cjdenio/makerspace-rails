require 'rails_helper'

RSpec.describe 'Group volunteer checkout dates' do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:tools) { Array.new(2) { create(:tool, shop: shop) } }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: tools.map { |tool| tool.id.to_s }) }
  let(:request) { CheckoutApproverRequest.create!(member: member, tool_group: group) }
  before do
    tools.each_with_index do |tool, index|
      ToolCheckout.create!(member: member, tool: tool, checked_out_at: Time.utc(2026, 4, 5 + index), defer_users_channel_invitation: true)
    end
  end
  it 'uses the completion date in the modal and reviewer notification' do
    manager = create(:member, :current, :resource_manager, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: manager, slack_id: 'UDATE')
    allow_any_instance_of(Member).to receive(:direct_notifications_suppressed?).and_return(false)
    view = SlackCheckoutModal.new(member: manager, shop: shop, tool: group, volunteer_request: request,
      metadata: { 'step' => 'volunteer_detail' }).build
    expect(view.to_json).to include('Checked out: 2026-04-06')
    expect(Service::SlackConnector).to receive(:send_slack_message).with(include('Checked out: 2026-04-06'), 'UDATE')
    CheckoutApproverVolunteering.deliver_request_notifications(request)
  end
  it 'does not claim completion if current group membership is not fully held' do
    request
    extra = create(:tool, shop: shop)
    group.update!(included_tool_ids: group.included_tool_ids + [extra.id.to_s])
    expect(request.reload.checkout_completed_on).to eq('Unknown')
  end
  it 'preserves the single-tool date' do
    single = CheckoutApproverRequest.create!(member: member, tool: tools.first)
    expect(single.checkout_completed_on).to eq('2026-04-05')
  end
end
