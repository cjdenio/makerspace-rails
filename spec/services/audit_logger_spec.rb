require 'rails_helper'

RSpec.describe Service::AuditLogger do
  let(:actor)          { create(:member, firstname: 'Todd', lastname: 'Hannemann') }
  let(:subject_member) { create(:member, firstname: 'Jane', lastname: 'Smith') }

  let(:base_params) do
    {
      log_type:      'member',
      event_type:    'member_updated',
      resource_type: 'Member',
      resource_id:   subject_member.id,
      actor:         actor,
      subject:       subject_member
    }
  end

  describe '.log' do
    context 'with valid required fields' do
      it 'creates an AuditLog document' do
        expect {
          described_class.log(**base_params)
        }.to change(AuditLog, :count).by(1)
      end

      it 'stores actor and subject correctly' do
        log = described_class.log(**base_params)
        expect(log.actor_id).to eq(actor.id)
        expect(log.actor_name).to eq('Todd Hannemann')
        expect(log.subject_id).to eq(subject_member.id)
        expect(log.subject_name).to eq('Jane Smith')
      end

      it 'always generates a slack_message even without a channel' do
        log = described_class.log(**base_params)
        expect(log.slack_message).to be_present
        expect(log.slack_posted).to be_nil
      end

      it 'stores field_changes when provided' do
        field_changes = { 'status' => ['activeMember', 'revoked'] }
        log = described_class.log(**base_params, field_changes: field_changes)
        expect(log.field_changes).to eq(field_changes)
        expect(log.slack_message).to include('activeMember')
        expect(log.slack_message).to include('revoked')
      end

      it 'appends human-readable message details when provided' do
        log = described_class.log(
          **base_params,
          message_details: 'shop: Woodshop, tool: Bandsaw'
        )

        expect(log.slack_message).to include('shop: Woodshop, tool: Bandsaw')
      end

      it 'scrubs sensitive fields from before_snapshot' do
        before_snap = {
          'firstname'            => 'Jane',
          'encrypted_password'   => 'supersecret',
          'otp_secret_encrypted' => 'topsecret',
          'session_token'        => 'abc123'
        }
        log = described_class.log(**base_params, before_snapshot: before_snap)
        expect(log.before_snapshot).to include('firstname' => 'Jane')
        expect(log.before_snapshot.keys).not_to include('encrypted_password', 'otp_secret_encrypted', 'session_token')
      end

      it 'scrubs sensitive fields from after_snapshot' do
        after_snap = { 'firstname' => 'Jane', 'encrypted_password' => 'newsecret' }
        log = described_class.log(**base_params, after_snapshot: after_snap)
        expect(log.after_snapshot.keys).not_to include('encrypted_password')
      end

      it 'stores nil snapshots without error (creation events)' do
        log = described_class.log(**base_params, before_snapshot: nil, after_snapshot: nil)
        expect(log.before_snapshot).to be_nil
        expect(log.after_snapshot).to be_nil
      end
    end

    context 'with Current.actor fallback' do
      it 'uses Current.actor when actor is not passed' do
        Current.actor = actor
        log = described_class.log(**base_params.except(:actor))
        expect(log.actor_id).to eq(actor.id)
        expect(log.actor_name).to eq('Todd Hannemann')
        Current.actor = nil
      end
    end

    context 'system-initiated events (no actor)' do
      it 'persists with nil actor fields' do
        Current.actor = nil
        log = described_class.log(**base_params.except(:actor))
        expect(log.actor_id).to be_nil
        expect(log.actor_name).to be_nil
      end
    end

    context 'portal log_type (no subject)' do
      it 'persists without subject fields' do
        log = described_class.log(
          log_type:      'portal',
          event_type:    'portal_setting_changed',
          resource_type: 'SystemConfig',
          resource_id:   BSON::ObjectId.new,
          actor:         actor,
          field_changes: { 'billing' => ['false', 'true'] }
        )
        expect(log.subject_id).to be_nil
        expect(log.subject_name).to be_nil
        expect(log).to be_persisted
      end
    end

    context 'Slack posting' do
      it 'does not call Slack when no channel is provided' do
        expect(::Service::SlackConnector).not_to receive(:send_slack_message)
        described_class.log(**base_params)
      end

      it 'calls Slack and sets slack_posted true when channel is provided' do
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_return(true)
        log = described_class.log(**base_params, slack_channel: '#member-relations')
        expect(log.slack_channel).to eq('#member-relations')
        expect(log.slack_posted).to eq(true)
      end

      it 'sets slack_posted false and notifies Honeybadger when Slack fails' do
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_raise('Slack error')
        allow(Honeybadger).to receive(:notify)
        log = described_class.log(**base_params, slack_channel: '#member-relations')
        expect(log.slack_posted).to eq(false)
        expect(Honeybadger).to have_received(:notify)
      end
    end

    context 'missing required fields' do
      %i[log_type event_type resource_type resource_id].each do |field|
        it "raises ArgumentError and notifies Honeybadger when #{field} is missing" do
          allow(Honeybadger).to receive(:notify)
          params = base_params.merge(field => nil)
          expect {
            described_class.log(**params)
          }.to raise_error(ArgumentError, /#{field}/)
          expect(Honeybadger).to have_received(:notify)
        end
      end
    end

    context 'when AuditLog save fails' do
      it 'returns nil and notifies Honeybadger without raising' do
        allow_any_instance_of(AuditLog).to receive(:save!).and_raise(Mongoid::Errors::Validations.new(AuditLog.new))
        allow(Honeybadger).to receive(:notify)
        result = described_class.log(**base_params)
        expect(result).to be_nil
        expect(Honeybadger).to have_received(:notify)
      end
    end

    describe '.notify_honeybadger' do
      it 'filters sensitive context before writing to the Rails log' do
        error = StandardError.new('Audit delivery failed')
        context = { member_id: '123', token: 'super-secret-token' }
        allow(Honeybadger).to receive(:notify)

        expect(Rails.logger).to receive(:error) do |message|
          expect(message).to include('member_id', '123', '[FILTERED]')
          expect(message).not_to include('super-secret-token')
        end

        described_class.notify_honeybadger(error, context: context)

        expect(Honeybadger).to have_received(:notify).with(error, context: context)
      end
    end

    context 'message generation' do
      it 'includes event type, actor, subject, and resource' do
        log = described_class.log(**base_params)
        expect(log.slack_message).to include('Member updated')
        expect(log.slack_message).to include('Todd Hannemann')
        expect(log.slack_message).to include('Jane Smith')
        expect(log.slack_message).to include('Member')
      end

      it 'formats expirationTime as a date in change summary' do
        exp_ms = (Time.now + 30.days).to_i * 1000
        field_changes = { 'expirationTime' => [nil, exp_ms] }
        log = described_class.log(**base_params, field_changes: field_changes)
        expect(log.slack_message).to match(%r{\d{2}/\d{2}/\d{4}})
        expect(log.slack_message).not_to include(exp_ms.to_s)
      end

      it 'handles nil actor gracefully in message' do
        Current.actor = nil
        log = described_class.log(**base_params.except(:actor))
        expect(log.slack_message).not_to include('by ')
      end
    end
  end
end
