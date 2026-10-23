require 'rails_helper'

RSpec.describe ToolGroupCheckoutNotificationJob, requires_transactions: true do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  let(:actor) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(ToolGroupCheckout).to receive(:notify)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    allow(described_class).to receive(:perform_later).and_return(true)
  end

  it 'queues only committed IDs, then delivers the batch and reconciled announcements in the job' do
    request = ToolCheckoutRequest.create!(member: member, tool: tool)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(request.reload.status).to eq('closed')
    expect(ToolGroupCheckout).not_to have_received(:notify)
    args = [group.id.to_s, member.id.to_s, result[:checkouts].map { |row| row.id.to_s }, [request.id.to_s], result[:approval_batch_id], result[:notification_snapshot]]
    expect(described_class).to have_received(:perform_later).with(*args)
    expect_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    described_class.perform_now(*args)
    expect(ToolGroupCheckout).to have_received(:notify).with(nil, member, hash_including(approval_batch_id: result[:approval_batch_id]))
    ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(described_class).to have_received(:perform_later).once
  end

  it 'queues closed announcements when an all-held group request is resolved' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group,
      revision: group.revision, source: 'slack', request_id: request.id)
    expect(result[:checkouts]).to be_empty
    expect(described_class).to have_received(:perform_later).with(group.id.to_s, member.id.to_s, [], [request.id.to_s], nil, result[:notification_snapshot])
    expect_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    described_class.perform_now(group.id.to_s, member.id.to_s, [], [request.id.to_s], nil, result[:notification_snapshot])
    expect(ToolGroupCheckout).not_to have_received(:notify)
  end

  %w[edited destroyed].each do |catalog_change|
    it "uses the all-held approval snapshot after the group is #{catalog_change}" do
      group.update!(announce: true, announce_channel: 'C11111111')
      request = ToolCheckoutRequest.create!(member: member, tool_group: group, message_id: '123.456')
      other_group = ToolGroup.create!(shop: shop, name: 'Other kit', included_tool_ids: [tool.id.to_s],
        announce: true, announce_channel: 'C22222222')
      other_request = ToolCheckoutRequest.create!(member: member, tool_group: other_group, message_id: '789.012')
      tool.update!(announce_channel: 'C33333333')
      tool_request = ToolCheckoutRequest.create!(member: member, tool: tool, message_id: '345.678')
      ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
      result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group,
        revision: group.revision, source: 'slack', request_id: request.id)
      snapshot = result[:notification_snapshot]
      group_id = group.id.to_s
      if catalog_change == 'edited'
        replacement = create(:tool, shop: shop)
        group.update!(name: 'Changed kit', included_tool_ids: [replacement.id.to_s], announce_channel: 'C99999999')
      else
        group.destroy!
      end
      tool.update!(name: 'Changed tool')
      allow_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement).and_call_original
      allow(Service::SlackConnector).to receive(:update_slack_message)
      args = [group_id, member.id.to_s, [], result[:reconciled].map { |row| row.id.to_s }, nil, snapshot]

      described_class.perform_now(*ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize(args)))

      message = "*#{CheckoutDisplay.escape(member.fullname)}* has completed checkout for *Kit*: " \
        "#{CheckoutDisplay.escape(snapshot['tools'].first['name'])}."
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C11111111', request.message_id, message)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C22222222', other_request.message_id,
        include('*Other kit*: Changed tool.'))
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C33333333', tool_request.message_id,
        tool_request.reload.checkout_success_message)
      expect(Service::SlackConnector).not_to have_received(:update_slack_message).with('C99999999', anything, anything)
      expect(ToolGroupCheckout).not_to have_received(:notify)
    end
  end

  it 'delivers the approved catalog snapshot even after group and child edits' do
    SlackUser.create!(member: member, slack_id: 'UMEMBER')
    tool.update!(users_channel: 'COLD', wiki_url: 'https://old.example.test')
    group.update!(announce: true, announce_channel: 'CANNOUNCE')
    args = nil
    allow(described_class).to receive(:perform_later) { |*values| args = values; true }
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    snapshot = result[:notification_snapshot]
    group.set(name: 'Changed kit', revision: 99, included_tool_ids: [], announce_channel: 'CNEW')
    tool.set(name: 'Changed tool', users_channel: 'CNEW', wiki_url: 'https://new.example.test')
    allow(ToolGroupCheckout).to receive(:notify).and_call_original
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:channel_member?).and_return(false)
    allow(Service::SlackConnector).to receive(:invite_to_channel)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later)
    described_class.perform_now(*ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize(args)))
    expect(Service::AuditLogger).to have_received(:log).with(hash_including(
      after_snapshot: hash_including(group_revision: snapshot['revision'], included_tool_ids: [tool.id.to_s])))
    expect(Service::SlackConnector).to have_received(:invite_to_channel).with(snapshot['tools'].first['users_channel'], 'UMEMBER')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include('*Kit*'), snapshot['channel'])
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include('https://old.example.test'), 'UMEMBER')
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'CNEW')
  end

  describe 'announcement ownership after adding a child tool' do
    let(:added_tool) { create(:tool, shop: shop) }
    let(:historical_request) { ToolCheckoutRequest.find_by(message_id: 'historical-ts') }

    before do
      group.update!(announce: true, announce_channel: 'C11111111')
      held = ToolCheckout.create!(member: member, tool: tool,
        defer_users_channel_invitation: true, defer_group_callbacks: true)
      ToolCheckoutRequest.create!(member: member, tool_group: group, status: 'closed',
        checked_out: held, message_id: 'historical-ts', request_date: 1.day.ago)
      ToolGroupCatalog.save!(actor: actor, group: group, revision: group.revision,
        attributes: { included_tool_ids: [tool.id.to_s, added_tool.id.to_s], announce_channel: 'C22222222' })
      group.reload
      allow(ToolGroupCheckout).to receive(:notify).and_call_original
      allow_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement).and_call_original
      allow(Service::AuditLogger).to receive(:log)
      allow(Service::SlackConnector).to receive(:update_slack_message)
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(double(ts: 'fresh-ts'))
      allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later)
    end

    %w[none matching unannounced other_group].each do |request_kind|
      it "preserves historical posts when the current approval reconciles #{request_kind} requests" do
        current = case request_kind
        when 'matching', 'unannounced'
          ToolCheckoutRequest.create!(member: member, tool_group: group,
            message_id: request_kind == 'matching' ? 'current-ts' : nil)
        when 'other_group'
          other_group = ToolGroup.create!(shop: shop, name: 'Other kit', included_tool_ids: [added_tool.id.to_s],
            announce: true, announce_channel: 'C33333333')
          ToolCheckoutRequest.create!(member: member, tool_group: other_group, message_id: 'other-ts')
        end
        result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group,
          revision: group.revision, source: 'slack')
        expect(result[:reconciled].map(&:id)).to eq(current ? [current.id] : [])
        args = [group.id.to_s, member.id.to_s, result[:checkouts].map { |row| row.id.to_s },
          result[:reconciled].map { |row| row.id.to_s }, result[:approval_batch_id], result[:notification_snapshot]]

        described_class.perform_now(*ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize(args)))

        message = include("*Kit*: #{added_tool.name}.")
        if request_kind == 'matching'
          expect(Service::SlackConnector).to have_received(:update_slack_message).with('C22222222', 'current-ts', message)
          expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'C22222222')
        else
          expect(Service::SlackConnector).to have_received(:send_slack_message).with(message, 'C22222222')
        end
        expect(current.reload.message_id).to eq('fresh-ts') if request_kind == 'unannounced'
        if request_kind == 'other_group'
          expect(Service::SlackConnector).to have_received(:update_slack_message).with('C33333333', 'other-ts', include('*Other kit*'))
        end
        expect(historical_request.reload.message_id).to eq('historical-ts')
        expect(Service::SlackConnector).not_to have_received(:update_slack_message).with(anything, 'historical-ts', anything)
        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'C11111111')
      end
    end
  end

  it 'does not enqueue a rolled-back approval' do
    expect { ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: 0, source: 'slack') }.to raise_error(Error::Conflict)
    expect(described_class).not_to have_received(:perform_later)
  end

  it 'keeps committed approvals successful if enqueue fails without falling back to synchronous delivery' do
    allow(described_class).to receive(:perform_later).and_raise('Queue unavailable')
    allow(Service::ErrorReporter).to receive(:notify)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(result[:checkouts].first.reload).to be_persisted
    expect(ToolGroupCheckout).not_to have_received(:notify)
    expect(Service::ErrorReporter).to have_received(:notify).with('Checkout notification failed', context: { error_class: 'RuntimeError' })
  end

  it 'queues notifications from the stateful Slack request approval workflow' do
    SlackUser.create!(member: actor, slack_id: 'UAPPROVER')
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    metadata = SlackCheckoutModal.encode_metadata('member_id' => actor.id.to_s, 'shop_id' => shop.id.to_s,
      'slack_user_id' => 'UAPPROVER', 'step' => 'request_approve', 'record_id' => request.id.to_s, 'group_revision' => group.revision)
    SlackCheckoutWorkflow.new('type' => 'view_submission', 'user' => { 'id' => 'UAPPROVER' },
      'view' => { 'private_metadata' => metadata }).call
    expect(request.reload.status).to eq('closed')
    expect(described_class).to have_received(:perform_later).once
    expect(ToolGroupCheckout).not_to have_received(:notify)
  end
end
