require 'rails_helper'

RSpec.describe CardManagement, requires_transactions: true do
  let(:actor) { create(:member, :admin) }
  let(:member) { create(:member, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:card) { create(:card, uid: '000AFF', member: member) }

  it 'never executes writes without transaction support', requires_transactions: false do
    session = double('session', end_session: nil)
    allow(Card).to receive(:with_session).and_yield(session)
    allow(session).to receive(:with_transaction).and_raise(Mongo::Error::TransactionsNotSupported.new('standalone topology'))
    expect do
      described_class.transaction { raise 'Must not execute writes' }
    end.to raise_error(CardManagement::Unavailable, /replica set/)
  end

  it 'rolls back a new assignment and old-card invalidation when audit persistence fails' do
    existing = create(:card, uid: '01020304', member: member)
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect do
      described_class.assign!({ member_id: member.id, uid: '05060708' }, actor)
    end.to raise_error(CardManagement::Unavailable)
    expect(Card.where(uid: '05060708')).not_to exist
    expect(existing.reload.validity).to eq('activeMember')
  end

  it 'keeps an existing card active when duplicate assignment fails' do
    existing = create(:card, uid: '01020304', member: member)
    card
    expect { described_class.assign!({ member_id: member.id, uid: card.uid }, actor) }.to raise_error(CardManagement::Conflict)
    expect(existing.reload.validity).to eq('activeMember')
  end

  it 'rejects a stale release after membership renewal' do
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    version = described_class.version(card, member)
    member.set(expirationTime: 1.day.from_now.to_i * 1000)
    expect { described_class.release!(card.id, version, actor) }.to raise_error(CardManagement::Conflict)
    expect(Card.where(id: card.id)).to exist
  end

  it 'releases expired assignments and leaves the member intact' do
    card
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    described_class.release!(card.id, described_class.version(card.reload), actor)
    expect(Card.where(id: card.id)).not_to exist
    expect(Member.where(id: member.id)).to exist
    audits = AuditLog.where(event_type: 'card_released', resource_id: card.id)
    expect(audits.count).to eq(1)
    audit = audits.first
    expect(audit.actor_id).to eq(actor.id)
    expect(audit.subject_id).to eq(member.id)
    expect(audit.resource_type).to eq('Card')
    expect(audit.before_snapshot['uid']).to eq(card.uid)
    expect(audit.before_snapshot['member_id']).to eq(member.id)
    expect(audit.after_snapshot).to eq({})
  end

  it 'detects a renewal racing between eligibility checking and deletion' do
    card
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    token = described_class.version(card.reload)
    renewed = false
    allow(described_class).to receive(:reason).and_wrap_original do |original, *arguments|
      unless renewed
        renewed = true
        # Another request's write: separate thread/session, no card callback needed.
        Thread.new { Member.where(id: member.id).update_all(expirationTime: 1.day.from_now.to_i * 1000) }.value
      end
      original.call(*arguments)
    end
    expect { described_class.release!(card.id, token, actor) }.to raise_error(CardManagement::Conflict)
    expect(Card.where(id: card.id)).to exist
    expect(AuditLog.where(event_type: 'card_released', resource_id: card.id)).not_to exist
  end

  it 'releases lost orphaned cards, but not other orphaned cards' do
    card.update!(card_location: 'lost')
    member.delete
    orphan = card.reload
    expect(described_class.reason(orphan)).to eq('Lost card')
    described_class.release!(orphan.id, described_class.version(orphan), actor)
    expect(Card.where(id: orphan.id)).not_to exist
    audit = AuditLog.find_by(event_type: 'card_released', resource_id: orphan.id)
    expect(audit.actor_id).to eq(actor.id)
    expect(audit.subject_id).to be_nil
    expect(audit.before_snapshot['uid']).to eq(orphan.uid)
    expect(audit.before_snapshot['validity']).to eq('lost')
    expect(audit.after_snapshot).to eq({})
  end

  it 'does not grant release solely for stolen or suspended status', requires_transactions: false do
    card.update!(card_location: 'stolen')
    expect(described_class.reason(card, member)).to be_nil
    member.set(status: 'suspended')
    expect(described_class.reason(card, member)).to be_nil
  end

  it 'rolls back deletion if audit persistence fails' do
    card.update!(card_location: 'lost')
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect { described_class.release!(card.id, described_class.version(card), actor) }.to raise_error(CardManagement::Unavailable)
    expect(Card.where(id: card.id)).to exist
  end

  it 'audits the finalized assignment of a pending member before running external effects' do
    pending_member = create(:member, :current, status: 'pending')
    rejection = create(:rejection_card, uid: '05060708')
    allow(Service::AuditLogger).to receive(:attempt_slack).and_return(false)
    allow_any_instance_of(Card).to receive(:perform_assignment_effects!).and_wrap_original do |original|
      assigned = original.receiver
      audit = AuditLog.find_by(event_type: 'card_assigned', resource_id: assigned.id)
      expect(audit.after_snapshot['validity']).to eq('activeMember')
      # A separate session sees these writes only once the transaction commits.
      Thread.new do
        expect(Member.find(pending_member.id).status).to eq('activeMember')
        expect(Card.find(assigned.id).validity).to eq('activeMember')
        expect(AuditLog.find(audit.id)).to be_present
      end.value
      original.call
    end

    assigned = described_class.assign!({ member_id: pending_member.id, uid: rejection.uid }, actor)

    expect(pending_member.reload.status).to eq('activeMember')
    expect(assigned.reload.validity).to eq('activeMember')
    expect(rejection.reload.holder).to eq(pending_member.fullname)
    expect(AuditLog.find_by(event_type: 'card_assigned', resource_id: assigned.id)
      .after_snapshot['validity']).to eq(assigned.validity)
  end

  it 'rolls back pending-member activation and rejection-card updates if the audit fails' do
    pending_member = create(:member, :current, status: 'pending')
    rejection = create(:rejection_card, uid: '05060708')
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect_any_instance_of(Card).not_to receive(:perform_assignment_effects!)

    expect do
      described_class.assign!({ member_id: pending_member.id, uid: rejection.uid }, actor)
    end.to raise_error(CardManagement::Unavailable)

    expect(pending_member.reload.status).to eq('pending')
    expect(rejection.reload.holder).to be_nil
    expect(Card.where(uid: rejection.uid)).not_to exist
    expect(AuditLog.where(event_type: 'card_assigned')).not_to exist
  end

  { 'nfc' => 'NFC scan (client-reported)', 'import' => 'Reader import (client-reported)',
    nil => 'Unspecified', 'untrusted text' => 'Unspecified' }.each do |source, label|
    it "records assignment UID source #{source.inspect} in the persisted audit" do
      allow(Service::AuditLogger).to receive(:attempt_slack).and_return(false)
      assigned = described_class.assign!({ member_id: member.id, uid: '001B1A4D2F' }, actor, uid_source: source)
      audit = AuditLog.find_by(event_type: 'card_assigned', resource_id: assigned.id)
      expect(audit.slack_message).to include("Card UID source: #{label}")
      expect(audit.slack_message).not_to include('untrusted text')
      expect(audit.after_snapshot['uid']).to eq('001B1A4D2F')
      expect(audit.actor_id).to eq(actor.id)
    end
  end

  it 'restores a deleted card and removes its audit when release fails before commit' do
    card.update!(card_location: 'lost')
    revision = member.reload.card_operation_version
    allow_any_instance_of(Card).to receive(:delete).and_wrap_original do |original, *args|
      original.call(*args)
      raise CardManagement::Unavailable, 'Simulated failure after deletion'
    end

    expect do
      described_class.release!(card.id, described_class.version(card), actor)
    end.to raise_error(CardManagement::Unavailable, 'Simulated failure after deletion')
    expect(Card.where(id: card.id)).to exist
    expect(AuditLog.where(event_type: 'card_released', resource_id: card.id)).not_to exist
    expect(member.reload.card_operation_version).to eq(revision)
  end
end
