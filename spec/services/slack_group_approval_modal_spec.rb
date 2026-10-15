require 'rails_helper'

RSpec.describe SlackGroupApprovalModal do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, name: 'Bandsaw', open: false) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'All tools', included_tool_ids: [tool.id.to_s], requestable: true) }
  let(:actor) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(ToolGroupCheckout).to receive(:notify)
    SlackUser.create!(member: actor, slack_id: 'UGROUPAPPROVER')
  end
  def payload
    view = described_class.build(actor: actor, member: member, group: group, slack_user_id: 'UGROUPAPPROVER')
    { 'user' => { 'id' => 'UGROUPAPPROVER' }, 'view' => { 'private_metadata' => view[:private_metadata] } }
  end
  it 'reviews physical records and approves with Slack provenance' do
    expect(ToolGroupCheckoutNotificationJob).to receive(:perform_later).and_return(true)
    expect(described_class.submit!(payload)[:checkouts].map(&:signed_off_via)).to eq(['slack'])
    expect(ToolGroupCheckout).not_to have_received(:notify)
  end
  it 'rejects changed revisions and changed Slack identities without creating records' do
    submission = payload
    group.inc(revision: 1)
    expect { described_class.submit!(submission) }.to raise_error(Error::Conflict)
    submission['user']['id'] = 'UOTHER'
    expect { described_class.submit!(submission) }.to raise_error(Error::Forbidden)
    expect(ToolCheckout.where(member_id: member.id)).to be_empty
  end
  it 'orders physical tools before groups in the legacy request selector' do
    group
    view = SlackCheckoutRequestModal.build(shop, member)
    options = view[:blocks].first[:element][:options]
    expect(options.map { |option| option[:value] }).to eq([tool.id.to_s, "group:#{group.id}"])
    expect(options.last[:text][:text]).to start_with(':linked_paperclips:')
  end
end
