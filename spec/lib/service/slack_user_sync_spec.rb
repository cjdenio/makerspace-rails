require 'rails_helper'

RSpec.describe Service::SlackUserSync do
  describe '.sync_single' do
    let!(:member) { create(:member, email: 'member@example.com') }
    let(:client) { double('Slack client') }
    let(:response) do
      {
        'user' => {
          'id' => 'U123',
          'name' => 'member',
          'real_name' => 'Member Name',
          'profile' => { 'email' => member.email, 'real_name' => 'Member Name' }
        }
      }
    end

    before do
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(client).to receive(:users_info).with(user: 'U123').and_return(response)
      allow(Service::SlackProfileSync).to receive(:sync_one)
      allow(Service::AuditLogger).to receive(:log)
      allow(Service::MemberProvisioning).to receive(:invite_slack)
    end

    it 'reactivates a normally invalidated identity instead of creating a duplicate Slack ID' do
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      SlackUser.collection.find(_id: identity.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'slack_user_deleted' }
      )

      expect(described_class.sync_single('U123')).to eq(member)
      expect(SlackUser.find(identity.id).invalidated_at).to be_nil
    end

    it 'does not reactivate an identity quarantined after a member email change' do
      identity = SlackUser.create!(slack_id: 'U123', slack_email: member.email)
      SlackUser.collection.find(_id: identity.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'member_email_changed' }
      )

      expect(described_class.sync_single('U123')).to be_nil
      expect(SlackUser.unscoped.find(identity.id).invalidated_at).to be_present
    end

    it 'preserves an established member link and audits a changed Slack email' do
      other_member = create(:member, email: 'other@example.com')
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      response['user']['profile']['email'] = other_member.email

      expect(described_class.sync_single('U123')).to eq(member)
      expect(SlackUser.find(identity.id)).to have_attributes(
        member_id: member.id,
        slack_email: other_member.email
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_email_mismatch',
          resource_id: member.id,
          subject: member,
          field_changes: {
            'slack_email' => [member.email, other_member.email]
          },
          slack_channel: Service::SlackConnector.logs_channel,
          message_details: /established Member link was preserved/i
        )
      )
    end

    it 'does not reactivate a tombstone when the member already has a different active identity' do
      active_identity = SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)
      tombstone = SlackUser.create!(slack_id: 'U123', slack_email: 'stale-u123@example.com')
      SlackUser.collection.find(_id: tombstone.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'slack_user_deleted' }
      )

      result = nil
      expect { result = described_class.sync_single('U123') }.not_to raise_error

      expect(result).to be_nil
      expect(SlackUser.unscoped.find(tombstone.id).invalidated_at).to be_present
      expect(SlackUser.find(active_identity.id).slack_id).to eq('UACTIVE')
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_identity_conflict',
          resource_id: member.id,
          message_details: /already has a different active Slack identity/i
        )
      )
    end

    it 'does not abort or transfer either link when the changed email already has a Slack identity' do
      other_member = create(:member, email: 'other@example.com')
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      other_identity = SlackUser.create!(
        member: other_member,
        slack_id: 'UOTHER',
        slack_email: other_member.email
      )
      response['user']['profile']['email'] = other_member.email

      expect { described_class.sync_single('U123') }.not_to raise_error
      expect(SlackUser.find(identity.id)).to have_attributes(
        member_id: member.id,
        slack_email: member.email
      )
      expect(SlackUser.find(other_identity.id)).to have_attributes(
        member_id: other_member.id,
        slack_email: other_member.email,
        slack_id: 'UOTHER'
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_email_mismatch', resource_id: member.id)
      )
    end

    it 'does not create a duplicate identity when the member already has a different active Slack identity' do
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)

      expect { described_class.sync_single('U123') }.not_to raise_error

      expect(SlackUser.where(slack_id: 'U123')).not_to exist
      expect(SlackUser.find_by(slack_id: 'UACTIVE').member_id).to eq(member.id)
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_identity_conflict', resource_id: member.id)
      )
    end

    it 'does not create a new identity for a member who is not in good standing' do
      member.update!(status: 'revoked')
      allow(Service::SlackConnector).to receive(:send_slack_message)

      result = described_class.sync_single('U123')

      expect(result).to be_nil
      expect(SlackUser.where(slack_id: 'U123')).not_to exist
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_including('not in good standing'), ::Service::SlackConnector.logs_channel
      )
    end

    it 'does not resync an already-linked member who is no longer in good standing' do
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: 'stale@example.com')
      member.update!(status: 'inactive')
      allow(Service::SlackConnector).to receive(:send_slack_message)

      result = described_class.sync_single('U123')

      expect(result).to be_nil
      expect(SlackUser.find(identity.id).slack_email).to eq('stale@example.com')
    end
  end

  describe '.sync_all' do
    let(:client) { double('Slack client') }

    def slack_member(id, email, real_name)
      {
        'id' => id,
        'is_bot' => false,
        'deleted' => false,
        'name' => real_name,
        'profile' => { 'email' => email, 'real_name' => real_name }
      }
    end

    before do
      SystemConfig.set(SystemConfig::SLACK_SYNC_ENABLED, 'true')
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(Service::SlackConnector).to receive(:send_slack_message)
      allow(Service::SlackProfileSync).to receive(:sync_one)
      allow(Service::AuditLogger).to receive(:log)
      allow(Service::ErrorReporter).to receive(:notify)
      # create(:member) fires MemberSubscriber#send_slack_invite, which looks
      # up the member by email via this same client double — stub it to a
      # harmless "not found" so member creation in these examples doesn't
      # collide with the sync-specific users_list stubbing below.
      allow(client).to receive(:users_lookupByEmail).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('not_found'))
    end

    it "reports and skips instead of raising when a member already has a different active Slack identity, and still processes users after it" do
      member = create(:member, email: 'shared@example.com')
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)

      other_member = create(:member, email: 'other@example.com')

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          slack_member('UDUPLICATE', member.email, 'Duplicate Identity'),
          slack_member('UNEXT', other_member.email, 'Next User')
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      result = nil
      expect { result = described_class.sync_all }.not_to raise_error

      expect(result).to include(skipped: 1, created: 1)
      expect(SlackUser.where(slack_id: 'UDUPLICATE')).not_to exist
      expect(SlackUser.find_by(slack_id: 'UNEXT').member_id).to eq(other_member.id)
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_identity_conflict', resource_id: member.id)
      )
    end

    it "skips a member who is not in good standing, whether newly linking or already linked" do
      revoked_member = create(:member, email: 'revoked@example.com', status: 'revoked')
      SlackUser.create!(member: revoked_member, slack_id: 'USTALE', slack_email: 'old@example.com')
      other_member = create(:member, email: 'other@example.com')

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          slack_member('UREVOKED', revoked_member.email, 'Revoked Member'),
          slack_member('USTALE', revoked_member.email, 'Revoked Member Stale'),
          slack_member('UNEXT', other_member.email, 'Next User')
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      result = described_class.sync_all

      expect(result).to include(skipped: 2, created: 1)
      expect(SlackUser.where(slack_id: 'UREVOKED')).not_to exist
      expect(SlackUser.find(SlackUser.find_by(slack_id: 'USTALE').id).slack_email).to eq('old@example.com')
      expect(SlackUser.find_by(slack_id: 'UNEXT').member_id).to eq(other_member.id)
    end

    it "continues processing subsequent users after an unexpected per-user error" do
      member = create(:member, email: 'first@example.com')
      other_member = create(:member, email: 'second@example.com')

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          slack_member('UFAILS', member.email, 'Fails'),
          slack_member('USUCCEEDS', other_member.email, 'Succeeds')
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      allow(described_class).to receive(:sanitized_slack_user_attributes).and_call_original
      allow(described_class).to receive(:sanitized_slack_user_attributes)
        .with(hash_including(slack_email: member.email))
        .and_raise(StandardError, 'boom')

      result = nil
      expect { result = described_class.sync_all }.not_to raise_error

      expect(result).to include(created: 1, failed: 1)
      expect(SlackUser.where(slack_id: 'UFAILS')).not_to exist
      expect(SlackUser.find_by(slack_id: 'USUCCEEDS').member_id).to eq(other_member.id)
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError), context: hash_including(slack_id: 'UFAILS')
      )
    end
  end

  describe '.detect_conflicts' do
    let(:client) { double('Slack client') }

    def slack_member(id, email, real_name)
      {
        'id' => id,
        'is_bot' => false,
        'deleted' => false,
        'name' => real_name,
        'profile' => { 'email' => email, 'real_name' => real_name }
      }
    end

    before do
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(Service::AuditLogger).to receive(:log)
      allow(client).to receive(:users_lookupByEmail).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('not_found'))
    end

    it 'reports a conflict without writing anything' do
      member = create(:member, email: 'shared@example.com')
      SlackUser.create!(
        member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account'
      )

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [slack_member('UDUPLICATE', member.email, 'Duplicate Identity')],
        'response_metadata' => { 'next_cursor' => '' }
      )

      conflicts = described_class.detect_conflicts

      expect(conflicts).to contain_exactly(
        hash_including(
          slack_id: 'UDUPLICATE',
          member_id: member.id.to_s,
          conflicting_slack_id: 'UACTIVE',
          conflicting_slack_name: 'Real Account'
        )
      )
      expect(SlackUser.where(slack_id: 'UDUPLICATE')).not_to exist
    end

    it 'returns no conflicts when nothing is in conflict' do
      member = create(:member, email: 'resolved@example.com')
      SlackUser.create!(member: member, slack_id: 'UNEW', slack_email: member.email)

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [slack_member('UNEW', member.email, 'Now Linked')],
        'response_metadata' => { 'next_cursor' => '' }
      )

      expect(described_class.detect_conflicts).to eq([])
    end

    it 'does not report a conflict for a member who is not in good standing' do
      member = create(:member, email: 'revoked@example.com', status: 'revoked')
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [slack_member('UDUPLICATE', member.email, 'Duplicate Identity')],
        'response_metadata' => { 'next_cursor' => '' }
      )

      expect(described_class.detect_conflicts).to eq([])
    end

    it 'includes a persisted conflict that no longer reproduces via a live directory scan' do
      member = create(:member, email: 'shared@example.com')
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account')
      SlackIdentityConflict.create!(
        slack_id: 'UGONE', slack_name: 'Gone Identity', slack_email: 'gone@example.com',
        member_id: member.id, conflicting_slack_id: 'UACTIVE', conflicting_slack_name: 'Real Account',
        conflicting_slack_email: member.email, source: 'member_provisioning'
      )

      # The rejected identity no longer appears in the live directory at all --
      # e.g. deactivated since the conflict was originally reported.
      allow(client).to receive(:users_list).and_return(
        'ok' => true, 'members' => [], 'response_metadata' => { 'next_cursor' => '' }
      )

      conflicts = described_class.detect_conflicts

      expect(conflicts).to contain_exactly(
        hash_including(slack_id: 'UGONE', member_id: member.id.to_s, conflicting_slack_id: 'UACTIVE')
      )
    end

    it 'does not duplicate a conflict the live scan already found' do
      member = create(:member, email: 'shared@example.com')
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account')
      SlackIdentityConflict.create!(
        slack_id: 'UDUPLICATE', slack_name: 'Duplicate Identity', slack_email: member.email,
        member_id: member.id, conflicting_slack_id: 'UACTIVE', conflicting_slack_name: 'Real Account',
        conflicting_slack_email: member.email, source: 'bulk sync'
      )

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [slack_member('UDUPLICATE', member.email, 'Duplicate Identity')],
        'response_metadata' => { 'next_cursor' => '' }
      )

      expect(described_class.detect_conflicts.size).to eq(1)
    end

    it 'skips a persisted conflict whose member no longer exists' do
      SlackIdentityConflict.create!(
        slack_id: 'UGHOST', member_id: BSON::ObjectId.new, conflicting_slack_id: 'UACTIVE'
      )
      allow(client).to receive(:users_list).and_return(
        'ok' => true, 'members' => [], 'response_metadata' => { 'next_cursor' => '' }
      )

      expect(described_class.detect_conflicts).to eq([])
    end
  end

  describe 'persisting conflicts' do
    let(:client) { double('Slack client') }
    let(:member) { create(:member, email: 'member@example.com') }

    before do
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(Service::AuditLogger).to receive(:log)
      allow(client).to receive(:users_lookupByEmail).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('not_found'))
      allow(client).to receive(:users_info).with(user: 'UNEW').and_return(
        'user' => {
          'id' => 'UNEW', 'name' => 'member',
          'profile' => { 'email' => member.email, 'real_name' => 'Member Name' }
        }
      )
    end

    it 'persists an unresolved conflict when sync_single hits one' do
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account')

      described_class.sync_single('UNEW')

      persisted = SlackIdentityConflict.find_by(slack_id: 'UNEW')
      expect(persisted).to have_attributes(
        member_id: member.id,
        conflicting_slack_id: 'UACTIVE',
        source: 'single-user sync',
        resolved_at: nil
      )
    end

    it 'clears the persisted conflict once reassign_identity links the rejected identity' do
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account')
      described_class.sync_single('UNEW')
      expect(SlackIdentityConflict.find_by(slack_id: 'UNEW').resolved_at).to be_nil

      described_class.reassign_identity(slack_id: 'UNEW', member_id: member.id.to_s)

      expect(SlackIdentityConflict.find_by(slack_id: 'UNEW').resolved_at).to be_present
    end

    it 'clears the persisted conflict once dismiss_conflict quarantines the rejected identity' do
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email, real_name: 'Real Account')
      described_class.sync_single('UNEW')

      described_class.dismiss_conflict(slack_id: 'UNEW', member_id: member.id.to_s)

      expect(SlackIdentityConflict.find_by(slack_id: 'UNEW').resolved_at).to be_present
    end
  end

  describe '.reassign_identity' do
    let(:client) { double('Slack client') }
    let(:member) { create(:member, email: 'kennith@example.com') }

    before do
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(Service::SlackProfileSync).to receive(:sync_one)
      allow(Service::AuditLogger).to receive(:log)
      allow(client).to receive(:users_lookupByEmail).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('not_found'))
      allow(client).to receive(:users_info).with(user: 'UNEW').and_return(
        'user' => {
          'id' => 'UNEW',
          'name' => 'kennith',
          'profile' => { 'email' => member.email, 'real_name' => 'Kennith Jaggard' }
        }
      )
    end

    it 'unlinks the old identity, links the new one, and audits the change' do
      old_identity = SlackUser.create!(member: member, slack_id: 'UOLD', slack_email: member.email)

      result = described_class.reassign_identity(slack_id: 'UNEW', member_id: member.id.to_s, actor: nil)

      expect(result).to eq(member)
      expect(SlackUser.find_by(slack_id: 'UNEW').member_id).to eq(member.id)
      expect(SlackUser.unscoped.find(old_identity.id)).to have_attributes(
        member_id: nil,
        invalidation_reason: Service::SlackUserSync::MANUAL_REASSIGNMENT_REASON
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_identity_manually_reassigned', resource_id: member.id)
      )
    end

    it 'does not report a conflict for this member on a later conflict scan' do
      SlackUser.create!(member: member, slack_id: 'UOLD', slack_email: member.email)

      described_class.reassign_identity(slack_id: 'UNEW', member_id: member.id.to_s)

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          {
            'id' => 'UOLD', 'is_bot' => false, 'deleted' => false, 'name' => 'kennith',
            'profile' => { 'email' => member.email, 'real_name' => 'Kennith Jaggard' }
          },
          {
            'id' => 'UNEW', 'is_bot' => false, 'deleted' => false, 'name' => 'kennith',
            'profile' => { 'email' => member.email, 'real_name' => 'Kennith Jaggard' }
          }
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      expect(described_class.detect_conflicts).to eq([])
    end

    it 'raises when the member does not exist' do
      expect do
        described_class.reassign_identity(slack_id: 'UNEW', member_id: BSON::ObjectId.new.to_s)
      end.to raise_error(Mongoid::Errors::DocumentNotFound)
    end
  end

  describe '.dismiss_conflict' do
    let(:member) { create(:member, email: 'kennith@example.com') }

    before do
      allow(Service::AuditLogger).to receive(:log)
    end

    it 'quarantines a never-before-seen conflicting identity without linking it to anyone' do
      result = described_class.dismiss_conflict(
        slack_id: 'UNEW', member_id: member.id.to_s,
        slack_email: 'unew@example.com', slack_name: 'Duplicate Identity'
      )

      expect(result).to eq(member)
      dismissed = SlackUser.unscoped.find_by(slack_id: 'UNEW')
      expect(dismissed).to have_attributes(
        member_id: nil,
        invalidation_reason: Service::SlackUserSync::MANUAL_REASSIGNMENT_REASON
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_identity_conflict_dismissed', resource_id: member.id)
      )
    end

    it 'unlinks and quarantines an existing identity that was already linked to someone' do
      other_member = create(:member, email: 'other@example.com')
      identity = SlackUser.create!(member: other_member, slack_id: 'USTRAY', slack_email: other_member.email)

      described_class.dismiss_conflict(slack_id: 'USTRAY', member_id: member.id.to_s)

      expect(SlackUser.unscoped.find(identity.id)).to have_attributes(
        member_id: nil,
        invalidation_reason: Service::SlackUserSync::MANUAL_REASSIGNMENT_REASON
      )
    end

    it 'raises when the member does not exist' do
      expect do
        described_class.dismiss_conflict(slack_id: 'UNEW', member_id: BSON::ObjectId.new.to_s)
      end.to raise_error(Mongoid::Errors::DocumentNotFound)
    end
  end

  describe '.sanitized_slack_user_attributes' do
    it 'sanitizes Slack-sourced fields before atomic persistence' do
      attributes = described_class.sanitized_slack_user_attributes(
        slack_email: 'slack@example.com',
        name: 'Alice &lt;img src=x onerror=alert(1)&gt;',
        real_name: '<b>Real & R&D</b><script>alert(1)</script>'
      )

      expect(attributes).to eq(
        slack_email: 'slack@example.com',
        name: 'Alice ',
        real_name: 'Real & R&Dalert(1)'
      )
    end
  end
end
