require 'rails_helper'

RSpec.describe ToolGroupCheckout do
  let(:shop) { create(:shop) }
  let(:first) { create(:tool, shop: shop) }
  let(:second) { create(:tool, shop: shop, open: true, prerequisite_ids: [first.id.to_s]) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Workshop induction', included_tool_ids: [first.id.to_s, second.id.to_s], requestable: true) }
  let(:actor) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(described_class).to receive(:notify)
  end
  def approve(revision: group.revision)
    described_class.approve!(actor: actor, member: member, group: group, revision: revision)
  end

  it 'grants physical checkouts together including open tools and internal prerequisites' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    individual = ToolCheckoutRequest.create!(member: member, tool: first)
    result = approve
    expect(result[:checkouts].map(&:tool_id)).to contain_exactly(first.id, second.id)
    expect(result[:checkouts].map(&:approval_batch_id).uniq).to eq([result[:approval_batch_id]])
    expect(request.reload.status).to eq('closed')
    expect(individual.reload.status).to eq('closed')
    expect(approve[:checkouts]).to be_empty
  end

  it 'skips active records but blocks a group containing a revoked record' do
    checkout = ToolCheckout.create!(member: member, tool: first, defer_users_channel_invitation: true)
    expect(approve[:skipped].map(&:id)).to eq([checkout.id])
    checkout.set(revoked_at: Time.current)
    expect { approve }.to raise_error(Error::UnprocessableEntity, /revoked/)
  end

  it 'requires external prerequisites and rejects stale reviews' do
    prerequisite = create(:tool, shop: shop)
    group.update!(prerequisite_ids: [prerequisite.id.to_s])
    expect { approve }.to raise_error(Error::UnprocessableEntity, /prerequisite/)
    expect { approve(revision: 0) }.to raise_error(Error::Conflict)
    expect(ToolCheckout.where(member_id: member.id).count).to eq(0)
  end

  it 'does not infer group authority from separate individual assignments' do
    actor.update!(role: 'member')
    CheckoutApprover.create!(member: actor, tool_ids: group.included_tool_ids)
    expect { approve }.to raise_error(Error::Forbidden)
  end

  it 'rolls back the whole approval if a child insert fails' do
    allow(ToolCheckout).to receive(:create!).and_call_original
    allow(ToolCheckout).to receive(:create!).with(hash_including(tool_id: second.id.to_s)).and_raise('insert failure')
    expect { approve }.to raise_error('insert failure')
    expect(ToolCheckout.where(member_id: member.id).count).to eq(0)
  end

  it 'awards one credit and reverses it once across multiple revocations' do
    actor.update!(role: 'member')
    CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    rows = approve[:checkouts]
    expect(rows.map(&:volunteer_credit_id).uniq.length).to eq(1)
    expect(VolunteerCredit.where(member_id: actor.id, status: 'approved').sum(:credit_value)).to eq(0.25)
    rows.each { |row| CheckoutApproverCredit.reverse!(row) }
    expect(VolunteerCredit.where(member_id: actor.id, status: 'reversal').count).to eq(1)
  end

  it 'rejects a cancelled request after its review' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group, status: 'deleted')
    expect {
      described_class.approve!(actor: actor, member: member, group: group, revision: group.revision, request_id: request.id)
    }.to raise_error(Error::UnprocessableEntity, /no longer open/)
    expect(ToolCheckout.where(member_id: member.id)).to be_empty
  end

  it 'keeps committed records and avoids new credit when notification delivery fails and approval retries' do
    allow(described_class).to receive(:notify).and_call_original
    allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('Slack unavailable')
    group.update!(announce: true, announce_channel: 'C12345678')
    first_result = approve
    expect(first_result[:checkouts].size).to eq(2)
    retried = approve
    expect(retried[:checkouts]).to be_empty
    expect(retried[:approval_batch_id]).to eq(first_result[:approval_batch_id])
  end

  it 'serializes concurrent individual and group approvals through the shared catalog lock' do
    actor_id, member_id, tool_id, shop_id, group_id = actor.id, member.id, first.id, shop.id, group.id
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    # Exercise real Mongo transactions from independent threads while replacing
    # Redis with a process-local implementation of the same keyed lock contract.
    locks, guard = {}, Mutex.new
    allow(CheckoutMutationLock).to receive(:with) do |member_id:, tool_id:, &action|
      lock = guard.synchronize { locks[[member_id.to_s, tool_id.to_s]] ||= Mutex.new }
      lock.synchronize(&action)
    end
    allow(CheckoutCreation).to receive(:deliver_notifications)
    threads = [
      Thread.new do
        described_class.approve!(actor: Member.find(actor_id), member: Member.find(member_id),
          group: ToolGroup.find(group_id), revision: 1)
      end,
      Thread.new do
        begin
          CheckoutCreation.create!(actor_id: actor_id, member_id: member_id, tool_id: tool_id, shop_id: shop_id, source: 'portal')
        rescue Error::UnprocessableEntity
          # A group committed first; the individual request is already satisfied.
          nil
        end
      end
    ]
    threads.each(&:value)
    expect(ToolCheckout.where(member_id: member_id).pluck(:tool_id)).to contain_exactly(first.id, second.id)
    expect(request.reload.status).to eq('closed')
  end
end
