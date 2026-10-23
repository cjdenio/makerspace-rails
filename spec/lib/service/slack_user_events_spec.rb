require 'rails_helper'

RSpec.describe Service::SlackUserEvents do
  let!(:member) { create(:member, email: 'new.member@example.com') }
  let(:user) do
    {
      'id' => 'UNEWMEMBER',
      'name' => 'newmember',
      'real_name' => 'New Member',
      'profile' => {
        'email' => 'New.Member@example.com',
        'real_name' => 'New Member'
      }
    }
  end

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::AuditLogger).to receive(:log)
  end

  it 'links a new team member and sends the welcome message' do
    allow(SystemConfig).to receive(:get).and_call_original
    allow(SystemConfig).to receive(:get).with('slack_channel_new_members')
      .and_return('new-members-test')
    described_class.process('type' => 'team_join', 'user' => user)

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      member_id: member.id,
      slack_email: 'new.member@example.com',
      name: 'newmember',
      real_name: 'New Member'
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(/Welcome to the makerspace New Member! \(<@UNEWMEMBER>\)/, 'new-members-test')
  end

  it 'updates profile details without welcoming for user_change' do
    SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: 'old@example.com')

    described_class.process('type' => 'user_change', 'user' => user.merge('name' => 'new-name'))

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      slack_email: 'new.member@example.com',
      name: 'new-name'
    )
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'audits a changed Slack email without relinking or changing the Member email' do
    allow(Service::AuditLogger).to receive(:log).and_call_original
    other_member = create(:member, email: 'changed@example.com')
    SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: member.email)
    changed_user = user.merge('profile' => user['profile'].merge('email' => other_member.email))

    described_class.process(
      { 'type' => 'user_change', 'user' => changed_user },
      event_id: 'Ev-email-change'
    )

    expect(member.reload.email).to eq('new.member@example.com')
    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      member_id: member.id,
      slack_email: 'changed@example.com'
    )
    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        event_type: 'slack_email_mismatch',
        resource_id: member.id,
        subject: member,
        field_changes: {
          'slack_email' => ['new.member@example.com', 'changed@example.com']
        },
        slack_channel: Service::SlackConnector.logs_channel,
        message_details: /admin must reconcile.*Ev-email-change/i
      )
    )
    expect(AuditLog.where(event_type: 'slack_email_mismatch', resource_id: member.id).count).to eq(1)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      /admin must reconcile.*Member email and Slack email/i,
      Service::SlackConnector.logs_channel
    )
  end

  it 'invalidates a deleted Slack user in place and hides the inactive link' do
    existing = SlackUser.create!(
      member: member,
      slack_id: 'UNEWMEMBER',
      slack_email: 'new.member@example.com'
    )

    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '200.0', 'user' => user.merge('deleted' => true) },
      event_id: 'Ev-deleted'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
    expect(member.reload.slack_user).to be_nil
    expect(SlackUser.unscoped.find(existing.id)).to have_attributes(
      member_id: member.id,
      slack_id: 'UNEWMEMBER',
      slack_email: 'new.member@example.com',
      invalidation_reason: 'slack_user_deleted; event_id=Ev-deleted'
    )
    expect(SlackUser.unscoped.find(existing.id).invalidated_at).to be_present
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'does not let an older user_change reactivate a deleted identity' do
    existing = SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: member.email)
    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '200.0', 'user' => user.merge('deleted' => true) },
      event_id: 'Ev-deleted'
    )

    described_class.process(
      { 'type' => 'team_join', 'event_ts' => '100.0', 'user' => user },
      event_id: 'Ev-stale-profile'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
    expect(SlackUser.unscoped.find(existing.id)).to have_attributes(
      invalidation_reason: 'slack_user_deleted; event_id=Ev-deleted',
      last_slack_event_ts: 200.0
    )
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'reactivates an identity only for a newer user_change' do
    existing = SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: member.email)
    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '200.0', 'user' => user.merge('deleted' => true) },
      event_id: 'Ev-deleted'
    )

    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '300.0', 'user' => user },
      event_id: 'Ev-new-profile'
    )

    expect(SlackUser.find(existing.id)).to have_attributes(
      invalidated_at: nil,
      invalidation_reason: nil,
      last_slack_event_ts: 300.0
    )
  end

  it 'links a replacement account that reuses an invalidated identity email' do
    old_identity = SlackUser.create!(
      member: member,
      slack_id: 'UOLD',
      slack_email: member.email
    )
    SlackUser.collection.find(_id: old_identity.id).update_one(
      '$set' => { invalidated_at: Time.current, invalidation_reason: 'slack_user_deleted' }
    )

    described_class.process(
      { 'type' => 'team_join', 'event_ts' => '300.0', 'user' => user },
      event_id: 'Ev-replacement'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      member_id: member.id,
      slack_email: member.email
    )
    expect(SlackUser.unscoped.find(old_identity.id).slack_id).to eq('UOLD')
  end

  it 'does not audit an email mismatch from an older event' do
    existing = SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: member.email)
    SlackUser.collection.find(_id: existing.id).update_one('$set' => { last_slack_event_ts: 200.0 })
    stale_user = user.merge('profile' => user['profile'].merge('email' => 'stale@example.com'))

    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '100.0', 'user' => stale_user },
      event_id: 'Ev-stale-email'
    )

    expect(Service::AuditLogger).not_to have_received(:log)
    expect(SlackUser.find(existing.id).slack_email).to eq(member.email)
  end

  it 'does not destroy a newer tombstone for a different identity when merging a stale event' do
    active_identity = SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)
    tombstoned_identity = SlackUser.create!(slack_id: 'UOLD_DELETED', slack_email: 'someone-else@example.com')
    SlackUser.collection.find(_id: tombstoned_identity.id).update_one(
      '$set' => {
        invalidated_at: Time.current,
        invalidation_reason: 'slack_user_deleted; event_id=Ev-newer-deletion',
        last_slack_event_ts: 200.0
      }
    )
    stale_user = user.merge('id' => 'UOLD_DELETED')

    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '100.0', 'user' => stale_user },
      event_id: 'Ev-stale-merge'
    )

    expect(SlackUser.unscoped.find(tombstoned_identity.id)).to have_attributes(
      invalidated_at: be_present,
      last_slack_event_ts: 200.0
    )
    expect(SlackUser.find(active_identity.id)).to have_attributes(
      slack_id: 'UACTIVE',
      last_slack_event_ts: nil
    )
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'keeps identities invalidated after a member email change quarantined' do
    old_identity = SlackUser.create!(slack_id: 'UNEWMEMBER', slack_email: member.email)
    SlackUser.collection.find(_id: old_identity.id).update_one(
      '$set' => {
        invalidated_at: Time.current,
        invalidation_reason: 'member_email_changed; revocation unavailable'
      }
    )

    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '300.0', 'user' => user },
      event_id: 'Ev-old-identity'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
    expect(SlackUser.unscoped.find(old_identity.id).member_id).to be_nil
  end

  it 'retries a failed welcome even when the retried event can no longer update the identity' do
    call_count = 0
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      call_count += 1
      raise StandardError, 'network blip' if call_count == 1
    end
    event = { 'type' => 'team_join', 'event_ts' => '100.0', 'user' => user }

    expect do
      described_class.process(event, event_id: 'Ev-welcome-retry')
    end.to raise_error(StandardError, 'network blip')

    created = SlackUser.find_by(slack_id: 'UNEWMEMBER')
    expect(created.welcomed_at).to be_nil
    expect(created.last_slack_event_ts).to eq(100.0)

    described_class.process(event, event_id: 'Ev-welcome-retry')

    expect(SlackUser.find(created.id).welcomed_at).to be_present
    expect(Service::SlackConnector).to have_received(:send_slack_message).twice
  end

  it 'creates a tombstone for a deletion event with no prior identity, blocking a later out-of-order join' do
    described_class.process(
      { 'type' => 'user_change', 'event_ts' => '200.0', 'user' => user.merge('deleted' => true) },
      event_id: 'Ev-unknown-deletion'
    )

    tombstone = SlackUser.unscoped.find_by(slack_id: 'UNEWMEMBER')
    expect(tombstone).to have_attributes(
      invalidation_reason: 'slack_user_deleted; event_id=Ev-unknown-deletion',
      last_slack_event_ts: 200.0
    )
    expect(tombstone.invalidated_at).to be_present

    described_class.process(
      { 'type' => 'team_join', 'event_ts' => '100.0', 'user' => user },
      event_id: 'Ev-stale-join-after-unknown-deletion'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  %w[is_bot is_app_user].each do |flag|
    it "ignores team_join when #{flag} is true" do
      described_class.process('type' => 'team_join', 'user' => user.merge(flag => true))

      expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
