require 'rails_helper'

RSpec.describe FixTicketService, requires_transactions: true do
  def member(role: 'member', status: 'activeMember', expiry: 30.days.from_now.to_i * 1000)
    id = BSON::ObjectId.new
    Member.collection.insert_one(_id: id, firstname: 'Test', lastname: id.to_s, email: "#{id}@example.com", role: role, status: status, expirationTime: expiry, member_contract_signed_date: Date.current)
    Member.find(id)
  end
  def report(actor, **attrs)
    described_class.create!(actor: actor, attributes: { title: 'Broken drill', description: 'Motor does not start', category: 'broken', submission_key: SecureRandom.uuid }.merge(attrs))
  end
  let(:reporter) { member }
  let(:admin) { member(role: 'admin') }
  it 'defaults donation identities to visible, respects opt-out, and preserves privacy on category edits' do
    donation = report(reporter, category: 'donation_offer')
    expect(donation.show_identity).to be(true)
    expect(FixTicketPresenter.ticket(donation, admin)[:reporter]).to eq(id: reporter.id.to_s, name: reporter.fullname)
    private_donation = report(reporter, category: 'donation_offer', show_identity: false)
    expect(FixTicketPresenter.ticket(private_donation, admin)).not_to have_key(:reporter)
    ordinary = report(reporter)
    described_class.update!(id: ordinary.id, actor: admin, attributes: { category: 'donation_offer' })
    expect(ordinary.reload.show_identity).to be(false)
    expect(FixTicketPresenter.ticket(ordinary, admin)).not_to have_key(:reporter)
  end
  it 'routes unscoped ticket creation and reporter notes to the staff channel' do
    ticket = report(reporter)
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'created').first.unscoped_staff_notification).to be(true)
    described_class.note!(id: ticket.id, actor: reporter, note: 'Additional details')
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'note').first.unscoped_staff_notification).to be(true)
    scoped = report(reporter, shop_id: create(:shop).id.to_s)
    expect(FixTicketEvent.where(ticket_id: scoped.id, kind: 'created').first.unscoped_staff_notification).to be(false)
  end
  it 'requires dual-role authors to choose and notifies other assignees' do
    ticket = report(reporter)
    assignee = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [reporter.id, assignee.id])
    expect { described_class.note!(id: ticket.id, actor: reporter, note: 'Repair update') }.to raise_error(Error::UnprocessableEntity, /Respond as/)
    %w[reporter assignee].each do |role|
      described_class.note!(id: ticket.id, actor: reporter, note: 'Repair update', respond_as: role)
      event = FixTicketEvent.where(ticket_id: ticket.id, kind: 'note').order_by(revision: :desc).first
      expect(event.recipients).to contain_exactly(assignee.id)
      expect(FixTicketPresenter.event_actor(event, ticket)).to eq(role == 'reporter' ? 'Reporter' : reporter.fullname)
    end
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'in_progress' })
    expect(FixTicketEvent.where(ticket_id: ticket.id).order_by(revision: :desc).first.recipients).to contain_exactly(reporter.id, assignee.id)
  end

  it 'preserves assignment notifications without looking up names for discarded deltas' do
    ticket = report(reporter)
    assignee = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [assignee.id])
    event = FixTicketEvent.where(ticket_id: ticket.id, kind: 'assigned').first
    expect(event.recipients).to contain_exactly(reporter.id, assignee.id)
    expect(event.field_changes).to eq({})
    described_class.assign!(id: ticket.id, actor: assignee, unassign_self: true)
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'assigned').order_by(revision: :desc).first.recipients).to eq([reporter.id])
  end
  it 'selects current relevant approvers and RMs with batched notification lookups' do
    shop = Shop.create!(name: 'Shop')
    tool = Tool.create!(shop: shop, name: 'Tool')
    rm = member(role: 'resource_manager')
    rm.set(resource_manager_shop_ids: [shop.id.to_s])
    approver = member
    expired = member(expiry: 1.day.ago.to_i * 1000)
    [approver, expired].each { |person| CheckoutApprover.create!(member_id: person.id, tool_ids: [tool.id.to_s]) }
    ticket = report(reporter, shop_id: shop.id, tool_id: tool.id)
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'created').first.recipients).to contain_exactly(rm.id, approver.id)
    described_class.note!(id: ticket.id, actor: approver, note: 'Investigating')
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'note').first.recipients).to contain_exactly(reporter.id, rm.id)
  end
  it 'rejects hidden catalog resources for ordinary reporters while preserving scoped management' do
    shop = Shop.create!(name: 'Private workshop')
    tool = Tool.create!(name: 'Private drill', shop: shop, disabled: true)
    attrs = { shop_id: shop.id.to_s, tool_id: tool.id.to_s, public_read_only: true }
    expect { report(reporter, **attrs) }.to raise_error(Error::Forbidden)
    expect(FixTicket.count).to eq(0)
    expect(FixTicketEvent.count).to eq(0)
    tool.update!(disabled: false, out_of_service: true)
    expect(report(reporter, **attrs)).to be_persisted
    shop.update!(disabled: true)
    expect { report(reporter, **attrs) }.to raise_error(Error::Forbidden)
    expect { report(reporter, shop_id: shop.id.to_s, uncatalogued_tool: 'Bench') }.to raise_error(Error::Forbidden)
    expect(FixTicketService.catalog_tools(reporter).pluck(:id)).not_to include(tool.id)
    expect(FixSlack.options(reporter, { 'action_id' => 'fix_search_tool_id', 'value' => 'Private' })[:options]).to be_empty
    manager = member(role: 'resource_manager')
    manager.set(resource_manager_shop_ids: [shop.id.to_s])
    [admin, member(role: 'board_member'), manager].each do |staff|
      tool.update!(disabled: true)
      expect(report(staff, **attrs)).to be_persisted
      expect(FixTicketService.catalog_tools(staff).pluck(:id)).to include(tool.id)
    end
    expect { report(member(role: 'resource_manager'), **attrs) }.to raise_error(Error::Forbidden)
  end
  it 'redacts reporter self-unassignment in stored and historical presentation' do
    ticket = report(reporter)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [reporter.id])
    described_class.assign!(id: ticket.id, actor: reporter, unassign_self: true)
    event = FixTicketEvent.where(ticket_id: ticket.id, kind: 'assigned').order_by(revision: :desc).first
    expect(event.field_changes).not_to have_key('assignees')
    # Old persisted deltas must be safe too, including queued Slack delivery.
    event.set(field_changes: { 'assignees' => [[reporter.fullname], []] })
    history = FixTicketPresenter.ticket(ticket.reload, admin, detail: true)[:events]
    expect(history.to_json).not_to include(reporter.fullname, reporter.id.to_s)
    expect(history.select { |e| e[:kind] == 'assigned' }.map { |e| e[:actor] }.uniq).to eq(['Member'])
  end
  it 'requires two non-whitespace characters for discussion notes without creating invalid events' do
    ticket = report(reporter)
    revision = ticket.revision
    ['', ' ', 'a', " a\n\t ", "\u00a0a\u00a0", '😀'].each do |note|
      expect { described_class.note!(id: ticket.id, actor: reporter, note: note) }.to raise_error(Error::UnprocessableEntity)
      expect(ticket.reload.revision).to eq(revision)
    end
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: ' a ' }) }.to raise_error(Error::UnprocessableEntity)
    described_class.note!(id: ticket.id, actor: reporter, note: ' a b ')
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'note').pluck(:note)).to eq(['a b'])
  end
  it 'does not execute writes without transaction support and exposes an actionable error', requires_transactions: false do
    session = double('session')
    allow(FixTicket).to receive(:with_session).and_yield(session)
    allow(session).to receive(:with_transaction).and_raise(
      Mongo::Error::TransactionsNotSupported.new('Transactions are not supported for the cluster: standalone topology')
    )
    expect do
      described_class.transaction(reporter.id) { raise 'Must not execute without a transaction' }
    end.to raise_error(Error::ServiceUnavailable, /standalone topology/)
    expect(reporter.reload.attributes['fix_ticket_write_revision']).to be_nil
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'inserts into a collision chain, stopping at a gap and keeping other reporters independent' do
    one = report(reporter, priority: 1)
    two = report(reporter, priority: 2)
    four = report(reporter, priority: 4)
    unrelated = report(member, priority: 1)
    fresh = report(reporter, priority: 1)
    expect([fresh.priority, one.reload.priority, two.reload.priority, four.reload.priority, unrelated.reload.priority]).to eq([1, 2, 3, 4, 1])
  end
  it 'clears priority overflow and rejects manual changes' do
    ten = report(reporter, priority: 10)
    report(reporter, priority: 10)
    expect(ten.reload.priority).to be_nil
    expect { described_class.update!(id: ten.id, actor: admin, attributes: { priority: 3 }) }.to raise_error(Error::UnprocessableEntity)
  end
  it 'enforces cap after downgrade and allows withdrawal from waiting for parts' do
    SystemConfig.set('ticket_open_limit', '1')
    first = report(admin)
    second = report(admin)
    admin.set(role: 'member')
    expect { report(admin) }.to raise_error(Error::UnprocessableEntity)
    first.set(status: 'waiting_for_parts')
    described_class.withdraw!(id: first.id, actor: admin)
    expect { report(admin) }.to raise_error(Error::UnprocessableEntity)
    described_class.withdraw!(id: second.id, actor: admin)
    expect(report(admin)).to be_persisted
  end
  it 'deduplicates a submission without another priority shift' do
    key = SecureRandom.uuid
    first = report(reporter, priority: 1, submission_key: key)
    same = report(reporter, priority: 1, submission_key: key)
    expect(same.id).to eq(first.id)
    expect(FixTicket.count).to eq(1)
  end
  it 'rejects pending and expired submissions' do
    expect { report(member(status: 'pending')) }.to raise_error(Error::Forbidden)
    expect { report(member(expiry: 1.day.ago.to_i * 1000)) }.to raise_error(Error::Forbidden)
  end
  it 'keeps public access read-only and excludes reporter identity' do
    ticket = report(reporter, public_read_only: true)
    viewer = member
    result = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(result.to_json).not_to include(reporter.id.to_s, reporter.fullname)
    expect { described_class.update!(id: ticket.id, actor: viewer, attributes: { note: 'injected' }) }.to raise_error(Error::Forbidden)
    expect { described_class.note!(id: ticket.id, actor: viewer, note: 'injected') }.to raise_error(Error::Forbidden)
    viewer.set(expirationTime: 1.day.ago.to_i * 1000)
    expect(FixTicketPolicy.new(viewer, ticket).read?).to be(false)
  end
  it 'grants assignment rights, retains them after expiry, and removes only assignment rights on self-unassignment' do
    ticket = report(reporter)
    volunteer = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    volunteer.set(expirationTime: 1.day.ago.to_i * 1000)
    described_class.note!(id: ticket.id, actor: volunteer, note: 'Looking into it')
    described_class.assign!(id: ticket.id, actor: volunteer, unassign_self: true)
    expect(FixTicketPolicy.new(volunteer, ticket.reload).read?).to be(false)
  end
  it 'requires closure and confirmation notes and reopens without priority' do
    ticket = report(reporter, priority: 1)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved' }) }.to raise_error(Error::UnprocessableEntity)
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Replaced switch' })
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Failed again' })
    expect(ticket.reload.priority).to be_nil
  end
  it 'atomically records every closure, clears attribution on reopen, and protects reporter privacy' do
    ticket = report(reporter)
    %w[resolved rejected].each do |status|
      described_class.update!(id: ticket.id, actor: admin, attributes: { status: status, note: 'Reviewed repair' })
      expect(ticket.reload.closed_by_id).to eq(admin.id)
      expect(FixTicketPresenter.ticket(ticket, reporter, detail: true)[:closedBy]).to eq({ id: admin.id.to_s, name: admin.fullname })
      described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Needs more work' })
      expect(ticket.reload.closed_by_id).to be_nil
    end
    described_class.withdraw!(id: ticket.id, actor: reporter)
    expect(ticket.reload.closed_by_id).to eq(reporter.id)
    expect(FixTicketPresenter.ticket(ticket, admin, detail: true).to_json).not_to include(reporter.id.to_s, reporter.fullname)
    audits = AuditLog.where(resource_id: ticket.id, event_type: 'ticket_closed')
    expect(audits.count).to eq(3)
    expect(audits.to_json).not_to include(reporter.id.to_s, reporter.fullname)
    expect(audits.where(actor_id: admin.id).count).to eq(2)
  end
  it 'rolls back closure and its event when audit persistence fails' do
    ticket = report(reporter)
    revision = ticket.revision
    allow(AuditLog).to receive(:create!).and_raise('Audit unavailable')
    expect { described_class.withdraw!(id: ticket.id, actor: reporter) }.to raise_error('Audit unavailable')
    expect(ticket.reload.status).to eq('open')
    expect(ticket.closed_by_id).to be_nil
    expect(ticket.revision).to eq(revision)
  end
  it 'advances meaningful timestamps but not delivery bookkeeping' do
    ticket = report(reporter)
    created = ticket.created_at
    travel 1.minute do
      described_class.note!(id: ticket.id, actor: reporter, note: 'More details')
      expect(ticket.reload.updated_at).to be > created
      updated = ticket.updated_at
      ticket.set(slack_ticket_ts: '123.456')
      expect(ticket.reload.updated_at).to eq(updated)
      expect(ticket.created_at).to eq(created)
    end
  end
  it 'filters and sorts before pagination and keeps unspecified priority last in descending order' do
    report(reporter, priority: nil)
    one = report(reporter, priority: 1)
    ten = report(reporter, priority: 10)
    result = FixTicketQuery.call(reporter, { mode: 'mine', direction: 'desc', page_size: 1 })
    expect(result[:total]).to eq(3)
    expect(result[:tickets].first[:id]).to eq(ten.id.to_s)
    expect(FixTicketQuery.call(reporter, { mode: 'mine', priority: '1' })[:tickets].first[:id]).to eq(one.id.to_s)
  end
  it 'publishes a linked bounty atomically and locks public visibility' do
    shop = create(:shop)
    ticket = report(reporter, shop_id: shop.id.to_s)
    expect { described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: '' }) }.to raise_error(Mongoid::Errors::Validations)
    expect(VolunteerSlackCanvasSyncJob).not_to have_been_enqueued
    expect(ticket.reload.public_read_only).to be(false)
    expect { described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 }) }.to have_enqueued_job(VolunteerSlackCanvasSyncJob).with(shop.id.to_s)
    expect(ticket.reload.bounty.ticket_id).to eq(ticket.id)
    expect(ticket.public_read_only).to be(true)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { public_read_only: false }) }.to raise_error(Error::UnprocessableEntity)
    expect { described_class.withdraw!(id: ticket.id, actor: reporter) }.to have_enqueued_job(VolunteerSlackCanvasSyncJob).with(shop.id.to_s)
    expect(ticket.bounty.reload.status).to eq('cancelled')
  end
  it 'allows an explicit replacement bounty after reopening, retaining cancelled history' do
    ticket = report(reporter)
    attrs = { title: 'Repair', description: 'Replace switch', credit_value: 1 }
    described_class.bounty!(id: ticket.id, actor: admin, attributes: attrs)
    old = ticket.reload.bounty
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired' })
    expect(old.reload.status).to eq('cancelled')
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Still broken', public_read_only: false })
    expect(FixTicketPolicy.new(admin, ticket.reload).capabilities[:canCreateBounty]).to be(true)
    expect { described_class.bounty!(id: ticket.id, actor: admin, attributes: attrs.merge(description: '')) }.to raise_error(Mongoid::Errors::Validations)
    expect(ticket.reload.bounty_id).to eq(old.id)
    expect(ticket.public_read_only).to be(false)
    described_class.bounty!(id: ticket.id, actor: admin, attributes: attrs)
    replacement = ticket.reload.bounty
    expect(replacement.id).not_to eq(old.id)
    expect(replacement.status).to eq('available')
    expect(old.reload).to have_attributes(status: 'cancelled', ticket_id: ticket.id)
    expect(ticket.public_read_only).to be(true)
    described_class.bounty!(id: ticket.id, actor: admin, attributes: attrs)
    expect(ticket.reload.bounty_id).to eq(replacement.id)
    expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'bounty').order_by(revision: :desc).first.field_changes['bounty_id']).to eq([old.id, replacement.id])
  end

  it 'blocks pending reward review after reopening until the ticket is resolved again' do
    ticket = report(reporter)
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired', nominate_reward: true })
    reviewer = member(role: 'board_member')
    reward_id = ticket.reload.reward_id
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Still broken' })
    expect(FixTicketPolicy.new(reviewer, ticket.reload).capabilities[:canReviewReward]).to be(false)
    expect_any_instance_of(VolunteerCredit).not_to receive(:notify_member_credit_awarded)
    expect_any_instance_of(VolunteerCredit).not_to receive(:check_discount_threshold!)
    [true, false].each do |approve|
      expect { described_class.review_reward!(id: ticket.id, actor: reviewer, approve: approve) }.to raise_error(Error::UnprocessableEntity, /must be resolved/)
    end
    expect(VolunteerCredit.find(reward_id).status).to eq('pending')
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Fixed again' })
    expect(FixTicketPolicy.new(reviewer, ticket.reload).capabilities[:canReviewReward]).to be(true)
    described_class.review_reward!(id: ticket.id, actor: reviewer, approve: false)
    expect(VolunteerCredit.find(reward_id).status).to eq('rejected')
  end

  it 'uses the independently configured ticket bounty credit maximum' do
    ticket = report(reporter)
    expect { described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 5 }) }.to raise_error(Mongoid::Errors::Validations)
    expect(ticket.reload.bounty_id).to be_nil
    SystemConfig.set('ticket_bounty_max_credit', '5')
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 5 })
    expect(ticket.reload.bounty.credit_value).to eq(5)
    expect { VolunteerTask.create!(title: 'Ordinary task', description: 'Work', created_by_id: admin.id, credit_value: 5) }.to raise_error(Mongoid::Errors::Validations)
  end
  %w[claimed pending].each do |state|
    it "requires claim cleanup before cancelling a #{state} linked bounty" do
      ticket = report(reporter)
      described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
      task = ticket.reload.bounty
      task.update!(status: state, claimed_by_id: reporter.id)
      ticket.update!(bounty_assignee_ids: [reporter.id], assignee_ids: [reporter.id])
      expect { task.cancel! }.to raise_error(Error::Forbidden, /Release or reject/)
      expect(task.reload.status).to eq(state)
      expect(ticket.reload.bounty_assignee_ids).to eq([reporter.id])
    end
  end
  it 'serializes concurrent submissions at the cap' do
    SystemConfig.set('ticket_open_limit', '1')
    person = reporter
    gate = Queue.new
    results = 2.times.map do
      Thread.new do
        gate.pop
        begin
          report(Member.find(person.id))
        rescue Error::UnprocessableEntity => error
          error
        end
      end
    end
    2.times { gate << true }
    values = results.map(&:value)
    expect(values.count { |v| v.is_a?(FixTicket) }).to eq(1)
    expect(FixTicket.where(reporter_id: person.id).count).to eq(1)
  end
  it 'requires an independent anonymous reward reviewer and prevents duplicate rewards' do
    ticket = report(reporter)
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired', nominate_reward: true })
    credit_id = ticket.reload.reward_id
    expect { described_class.review_reward!(id: ticket.id, actor: admin, approve: true) }.to raise_error(Error::Forbidden)
    reviewer = member(role: 'admin')
    allow_any_instance_of(VolunteerCredit).to receive(:notify_member_credit_awarded)
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
    described_class.review_reward!(id: ticket.id, actor: reviewer, approve: true)
    expect(VolunteerCredit.find(credit_id).status).to eq('approved')
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Regression' })
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired again', nominate_reward: true })
    expect(ticket.reload.reward_id).to eq(credit_id)
    expect(FixTicketPresenter.ticket(ticket, reviewer, detail: true).to_json).not_to include(reporter.id.to_s)
  end

  it 'does not enqueue claim canvas sync when ticket assignment writes roll back' do
    ticket = report(reporter)
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    claimant = member
    allow(task).to receive(:enqueue_volunteer_canvas_sync)
    allow(described_class).to receive(:event!).and_raise('Assignment failed')
    expect { task.claim!(claimant) }.to raise_error('Assignment failed')
    expect(task.reload.status).to eq('available')
    expect(task).not_to have_received(:enqueue_volunteer_canvas_sync)
    allow(described_class).to receive(:event!).and_call_original
    task.claim!(claimant)
    expect(task).to have_received(:enqueue_volunteer_canvas_sync).with(struck_task_id: task.id).once
    expect(ticket.reload.assignee_ids).to include(claimant.id)
  end
  it 'preserves manual assignments when a bounty claim is released after ticket closure' do
    ticket = report(reporter)
    volunteer = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    allow(task).to receive(:enqueue_volunteer_canvas_sync)
    allow(task).to receive(:notify_member_task_released)
    task.claim!(volunteer)
    expect(ticket.reload.bounty_assignee_ids).to include(volunteer.id)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    described_class.withdraw!(id: ticket.id, actor: reporter)
    expect(task.reload.status).to eq('claimed')
    task.release!(admin, 'Cannot complete')
    expect(task.reload.status).to eq('cancelled')
    expect(ticket.reload.assignee_ids).to include(volunteer.id)
    expect(ticket.bounty_assignee_ids).to be_empty
  end
  it 'forbids reporter claims even for an admin and preserves active claimants in staff assignment edits' do
    ticket = report(admin)
    described_class.bounty!(id: ticket.id, actor: member(role: 'admin'), attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    expect { task.claim!(admin) }.to raise_error(Error::Forbidden, /reporter cannot claim/)
    expect(task.reload.status).to eq('available')
    claimant = member
    task.claim!(claimant)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [])
    expect(ticket.reload.bounty_assignee_ids).to eq([claimant.id])
    expect(ticket.assignee_ids).to eq([claimant.id])
    claimant.set(expirationTime: 1.day.ago.to_i * 1000)
    expect(FixTicketPolicy.new(claimant, ticket).change_status?).to be(true)
  end

  { release!: ['claimed', :notify_member_task_released], reject_pending!: ['pending', :notify_member_task_rejected] }.each do |operation, (state, notification)|
    it "defers #{operation} effects until assignment writes commit" do
      ticket = report(reporter)
      described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
      task = ticket.reload.bounty
      claimant = member
      task.update!(status: state, claimed_by_id: claimant.id)
      ticket.update!(bounty_assignee_ids: [claimant.id], assignee_ids: [claimant.id])
      allow(task).to receive(notification)
      allow(task).to receive(:enqueue_volunteer_canvas_sync)
      allow(described_class).to receive(:event!).and_raise('Simulated transaction abort')
      expect { task.public_send(operation, admin, 'Cannot finish') }.to raise_error(/Simulated transaction abort/)
      expect(task.reload.status).to eq(state)
      expect(ticket.reload.assignee_ids).to eq([claimant.id])
      expect(task).not_to have_received(notification)
      expect(task).not_to have_received(:enqueue_volunteer_canvas_sync)
      allow(described_class).to receive(:event!).and_call_original
      task.public_send(operation, admin, 'Cannot finish')
      expect(task).to have_received(notification).with(claimant.id, 'Cannot finish').once
      expect(task).to have_received(:enqueue_volunteer_canvas_sync).once
      expect(ticket.reload.assignee_ids).to be_empty
    end
  end

  it 'restricts report names on creation and editing, including Slack service calls' do
    expect { report(reporter, title: 'Drill <script>') }.to raise_error(Error::UnprocessableEntity)
    expect { report(reporter, uncatalogued_tool: 'Saw @channel') }.to raise_error(Error::UnprocessableEntity)
    ticket = report(reporter, title: 'Drill-2 (bench), 1/4 in.', uncatalogued_tool: 'Drill_press / 2')
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { title: 'Saw <img>' }) }.to raise_error(Mongoid::Errors::Validations)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { uncatalogued_tool: "Saw\nName" }) }.to raise_error(Mongoid::Errors::Validations)
    expect(ticket.reload.title).to eq('Drill-2 (bench), 1/4 in.')
  end

  %w[admin board_member resource_manager].each do |role|
    it "requires actual prerequisite checkouts for a #{role} claiming a ticket bounty" do
      tool = create(:tool, shop: create(:shop))
      ticket = report(reporter, shop_id: tool.shop_id.to_s)
      described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1, prerequisite_tool_ids: [tool.id.to_s] })
      task = ticket.reload.bounty
      claimant = member(role: role)
      expect(task.eligible_for?(claimant)).to be(false)
      ordinary = VolunteerTask.new(title: 'Ordinary', description: 'Work', credit_value: 1, prerequisite_tool_ids: [tool.id.to_s])
      expect(ordinary.eligible_for?(claimant)).to be(true)
      expect { task.claim!(claimant) }.to raise_error(Error::Forbidden)
      expect(task.reload.status).to eq('available')
      expect(ticket.reload.assignee_ids).not_to include(claimant.id)
      create(:tool_checkout, member: claimant, tool: tool)
      task.claim!(claimant)
      expect(task.reload.claimed_by_id).to eq(claimant.id)
      expect(ticket.reload.bounty_assignee_ids).to include(claimant.id)
    end
  end

  it 'does not turn a bounty claimant into a manual assignee when staff edits the effective list' do
    ticket = report(reporter)
    claimant, helper = member, member
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    allow(task).to receive(:enqueue_volunteer_canvas_sync)
    allow(task).to receive(:notify_member_task_released)
    task.claim!(claimant)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [claimant.id, helper.id])
    expect(ticket.reload.manual_assignee_ids).to eq([helper.id])
    expect(ticket.bounty_assignee_ids).to eq([claimant.id])
    task.release!(admin, 'Unable to finish')
    expect(ticket.reload.assignee_ids).to eq([helper.id])
    expect(FixTicketPolicy.new(claimant, ticket).note?).to be(false)
    expect(FixTicketPolicy.new(claimant, ticket).change_status?).to be(false)
  end

end
