require 'rails_helper'
require 'timeout'

RSpec.describe 'Slack group request workflow' do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s], requestable: true) }
  let(:member) { create(:member, :current) }
  let(:actor) { create(:member, :current, :admin) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    SlackUser.create!(member: member, slack_id: 'UREQUESTER')
    allow(SlackCheckoutOutcomeJob).to receive(:enqueue)
    allow(CheckoutNotificationJob).to receive(:perform_later).and_return(true)
    allow(ToolGroupCheckout).to receive(:notify)
  end

  def payload(step, record_id)
    metadata = SlackCheckoutModal.encode_metadata('member_id' => member.id.to_s, 'shop_id' => shop.id.to_s,
      'slack_user_id' => 'UREQUESTER', 'step' => step, 'record_id' => record_id.to_s)
    { 'type' => 'view_submission', 'user' => { 'id' => 'UREQUESTER' },
      'view' => { 'private_metadata' => metadata, 'state' => { 'values' => {
        SlackCheckoutModal::NOTE => { SlackCheckoutModal::NOTE => { 'value' => 'Updated note' } }
      } } } }
  end

  it 'queues the stateful request and delivers its sends only when the job runs' do
    allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:notify_requestor)
    submission = payload('request_new', "group:#{group.id}")
    expect_any_instance_of(ToolCheckoutRequest).not_to receive(:announce_request)
    expect_any_instance_of(ToolCheckoutRequest).not_to receive(:notify_requestor)
    expect(SlackCheckoutWorkflow.new(submission).call).to eq(:clear)
    request = ToolCheckoutRequest.last
    expect(CheckoutNotificationJob).to have_received(:perform_later).with('request', request.id.to_s)
    expect { SlackCheckoutWorkflow.new(submission).call }.to raise_error(Error::UnprocessableEntity)
    expect(CheckoutNotificationJob).to have_received(:perform_later).once
  end

  it 'delivers both deferred group request notifications in the existing worker' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    expect_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
    expect_any_instance_of(ToolCheckoutRequest).to receive(:notify_requestor)
    CheckoutNotificationJob.perform_now('request', request.id.to_s)
  end

  it 'keeps the saved request successful when enqueue fails without inline sends' do
    allow(CheckoutNotificationJob).to receive(:perform_later).and_raise('queue unavailable')
    allow(Service::ErrorReporter).to receive(:notify)
    expect_any_instance_of(ToolCheckoutRequest).not_to receive(:announce_request)
    expect_any_instance_of(ToolCheckoutRequest).not_to receive(:notify_requestor)
    expect(SlackCheckoutWorkflow.new(payload('request_new', "group:#{group.id}")).call).to eq(:clear)
    expect(ToolCheckoutRequest.where(member: member, tool_group: group, status: 'open')).to exist
    expect(Service::ErrorReporter).to have_received(:notify).with('Checkout notification failed', anything)
  end

  it 'edits under the catalog and each constituent checkout lock' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    held = []
    allow(CheckoutMutationLock).to receive(:with) do |member_id:, tool_id:, &action|
      held.push([member_id.to_s, tool_id.to_s])
      begin
        action.call
      ensure
        held.pop
      end
    end
    allow_any_instance_of(ToolCheckoutRequest).to receive(:update!).and_wrap_original do |original, **attributes|
      expect(held).to include(['catalog', shop.id.to_s], [member.id.to_s, tool.id.to_s])
      original.call(**attributes)
    end
    expect(SlackCheckoutWorkflow.new(payload('request_edit', request.id)).call).to eq(:clear)
    expect(request.reload.note).to eq('Updated note')
  end

  %w[cancel approve].each do |winner|
    it "serializes cancellation and approval when #{winner} acquires the catalog first", requires_transactions: true do
      request = ToolCheckoutRequest.create!(member: member, tool_group: group)
      member_id, actor_id, group_id, revision = member.id, actor.id, group.id, group.revision
      submission = payload('request_cancel', request.id)
      locks, guard = {}, Mutex.new
      acquired, attempted, release = Queue.new, Queue.new, Queue.new
      allow(CheckoutMutationLock).to receive(:with) do |member_id:, tool_id:, &action|
        catalog = member_id.to_s == 'catalog'
        attempted << true if catalog && Thread.current[:operation] != winner
        lock = guard.synchronize { locks[[member_id.to_s, tool_id.to_s]] ||= Mutex.new }
        lock.synchronize do
          if catalog && Thread.current[:operation] == winner
            acquired << true
            release.pop
          end
          action.call
        end
      end
      operations = {
        'cancel' => -> { SlackCheckoutWorkflow.new(submission).call },
        'approve' => -> { ToolGroupCheckout.approve!(actor: Member.find(actor_id), member: Member.find(member_id),
          group: ToolGroup.find(group_id), revision: revision, request_id: request.id) }
      }
      start = ->(name) { Thread.new do
        Thread.current[:operation] = name
        begin
          operations.fetch(name).call
        rescue SlackCheckoutWorkflow::Rejected, Error::UnprocessableEntity => error
          error
        end
      end }
      first = start.call(winner)
      Timeout.timeout(10) { acquired.pop }
      second = start.call(winner == 'cancel' ? 'approve' : 'cancel')
      Timeout.timeout(10) { attempted.pop }
      release << true
      outcomes = Timeout.timeout(15) { [first.value, second.value] }
      expect(outcomes.first).not_to be_a(Exception)
      expect(outcomes.last).to be_a(winner == 'cancel' ? Error::UnprocessableEntity : SlackCheckoutWorkflow::Rejected)
      expect(request.reload.status).to eq(winner == 'cancel' ? 'deleted' : 'closed')
      expect(ToolCheckout.where(member_id: member_id).count).to eq(winner == 'cancel' ? 0 : 1)
    ensure
      release << true if release
      [first, second].compact.each { |thread| thread.join(5) || thread.kill }
    end
  end
end
