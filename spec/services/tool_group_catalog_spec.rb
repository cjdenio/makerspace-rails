require 'rails_helper'

RSpec.describe ToolGroupCatalog, requires_transactions: true do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:actor) { create(:member, :current, :admin) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'extends individual authority but never grants existing trainees new checkouts' do
    trainee = create(:member, :current)
    ToolCheckout.create!(member: trainee, tool: tool, defer_users_channel_invitation: true)
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    extra = create(:tool, shop: shop)
    allow(CheckoutApproverMutationLock).to receive(:with).with(member_id: actor.id.to_s).and_wrap_original do |lock, **args, &operation|
      lock.call(**args) do
        operation.call
        expect(group.reload.revision).to eq(2)
        expect(approver.reload.tool_ids).to include(extra.id.to_s)
      end
    end
    described_class.save!(actor: actor, group: group, revision: 1, attributes: { included_tool_ids: [tool.id.to_s, extra.id.to_s] })
    expect(approver.reload.tool_ids).to contain_exactly(tool.id.to_s, extra.id.to_s)
    expect(ToolCheckout.where(member: trainee, tool: extra)).not_to exist
    approver.update!(tool_group_ids: [], tool_ids: [])
    expect(approver.reload.tool_ids).to contain_exactly(tool.id.to_s, extra.id.to_s)
  end
  it 'archives open requests and retains individual grants' do
    member = create(:member, :current)
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    volunteer = CheckoutApproverRequest.create!(member: member, tool_group: group)
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    described_class.save!(actor: actor, group: group, revision: 1, attributes: { archived: true })
    expect(request.reload.status).to eq('deleted')
    expect(volunteer.reload.status).to eq('revoked')
    expect(approver.reload.tool_ids).to include(tool.id.to_s)
    expect(approver.tool_group_ids).to be_empty
    expect(group.reload.revision).to eq(2)
  end
  it 'rejects a resource manager assigned only to another shop' do
    actor.update!(role: 'resource_manager', resource_manager_shop_ids: [create(:shop).id.to_s])
    expect { described_class.save!(actor: actor, group: group, revision: 1, attributes: { name: 'Other' }) }.to raise_error(Error::Forbidden)
  end
  it 'rechecks revocation after locking and holds the approver lock through commit' do
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    extra = create(:tool, shop: shop)
    checkout = ToolCheckout.create!(member: actor, tool: extra, defer_users_channel_invitation: true)
    allow(CheckoutApproverMutationLock).to receive(:with).with(member_id: actor.id.to_s) do |&operation|
      # A revocation wins immediately before the catalog acquires this lock.
      checkout.approver_mutation_lock_held = true
      checkout.update!(revoked_at: Time.current, revocation_reason: 'Revoked')
      operation.call
      # Read independently of the transaction before releasing the lock.
      expect(group.reload.revision).to eq(2)
    end
    described_class.save!(actor: actor, group: group, revision: 1,
      attributes: { included_tool_ids: [tool.id.to_s, extra.id.to_s] })
    expect(CheckoutApproverMutationLock).to have_received(:with).with(member_id: actor.id.to_s)
    expect(approver.reload.tool_group_ids).to be_empty
    expect(approver.tool_ids).not_to include(extra.id.to_s)
    expect(approver.group_granted_tool_ids).not_to include(extra.id.to_s)
  end

  describe 'membership edit reconciliation' do
    let(:extra) { create(:tool, shop: shop) }
    let(:member) { create(:member, :current) }
    let(:checkout) do
      ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    end
    let(:request) { ToolCheckoutRequest.create!(member: member, tool_group: group, message_id: 'request-ts') }

    before do
      group.update!(included_tool_ids: [tool.id.to_s, extra.id.to_s], announce: true, announce_channel: 'C11111111')
      checkout
      request
      allow(Service::SlackConnector).to receive(:update_slack_message)
    end

    it 'closes only satisfied requests for the edited group and updates the original channel after commit' do
      incomplete = ToolCheckoutRequest.create!(member: create(:member, :current), tool_group: group)
      revoked_member = create(:member, :current)
      ToolCheckout.create!(member: revoked_member, tool: tool, revoked_at: Time.current,
        defer_users_channel_invitation: true, defer_group_callbacks: true)
      revoked = ToolCheckoutRequest.create!(member: revoked_member, tool_group: group)
      other_group = ToolGroup.create!(shop: shop, name: 'Other kit', included_tool_ids: [tool.id.to_s])
      unrelated = ToolCheckoutRequest.create!(member: member, tool_group: other_group)
      individual = ToolCheckoutRequest.create!(member: member, tool: tool)
      allow(Service::SlackConnector).to receive(:update_slack_message) do
        # An independent read must observe committed reconciliation at delivery.
        expect(ToolCheckoutRequest.find(request.id).status).to eq('closed')
        expect(ToolGroup.find(group.id).included_tool_ids).to eq([tool.id.to_s])
      end
      allow(CheckoutApproverMutationLock).to receive(:with).and_call_original
      expect(CheckoutApproverMutationLock).to receive(:with).with(member_id: member.id.to_s).and_call_original

      result = described_class.save!(actor: actor, group: group, revision: group.revision,
        attributes: { included_tool_ids: [tool.id.to_s], name: 'Reduced kit', announce_channel: 'C99999999' })

      expect(result.id).to eq(group.id)
      expect(request.reload.status).to eq('closed')
      expect(request.checked_out_id).to eq(checkout.id)
      expect([incomplete, revoked, unrelated, individual].map { |row| row.reload.status }).to eq(%w[open open open open])
      expect(ToolCheckout.where(member: member).pluck(:id)).to eq([checkout.id])
      expect(VolunteerCredit.count).to eq(0)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C11111111', 'request-ts',
        include("*Reduced kit*: #{CheckoutDisplay.escape(tool.name)}."))
      expect(Service::SlackConnector).not_to have_received(:update_slack_message).with('C99999999', anything, anything)
    end

    it 'keeps requests open when a membership edit adds an unheld tool' do
      added = create(:tool, shop: shop)
      described_class.save!(actor: actor, group: group, revision: group.revision,
        attributes: { included_tool_ids: [tool.id.to_s, extra.id.to_s, added.id.to_s] })
      expect(request.reload.status).to eq('open')
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end

    it 'prioritizes archival over reconciliation when the same edit removes an unheld tool' do
      described_class.save!(actor: actor, group: group, revision: group.revision,
        attributes: { included_tool_ids: [tool.id.to_s], archived: true })
      expect(request.reload.status).to eq('deleted')
      expect(request.checked_out_id).to be_nil
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end

    it 'rolls back the edit and reconciliation without announcing a failed transaction' do
      allow(ToolGroupCheckout).to receive(:reconcile!).and_wrap_original do |operation, *args, **options|
        operation.call(*args, **options)
        raise 'Failure after request reconciliation'
      end
      expect do
        described_class.save!(actor: actor, group: group, revision: group.revision,
          attributes: { included_tool_ids: [tool.id.to_s] })
      end.to raise_error('Failure after request reconciliation')
      expect(group.reload.included_tool_ids).to eq([tool.id.to_s, extra.id.to_s])
      expect(group.revision).to eq(1)
      expect(request.reload.status).to eq('open')
      expect(request.checked_out_id).to be_nil
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end
  end

end
