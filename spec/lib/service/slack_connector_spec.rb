require 'rails_helper'

RSpec.describe Service::SlackConnector do
  describe '.invite_to_slack' do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    it 'treats a missing admin token as disabled even when invites are enabled' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return(nil)

      expect(Slack::Web::Client).not_to receive(:new)

      expect do
        described_class.invite_to_slack('new.member@example.com', 'Member', 'New')
      end.to raise_error(Error::NotAllowed, 'Slack invites are not enabled in this environment')
    end

    it 'does not invite when the feature flag is disabled' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('false')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')

      expect(Slack::Web::Client).not_to receive(:new)

      expect do
        described_class.invite_to_slack('new.member@example.com', 'Member', 'New')
      end.to raise_error(Error::NotAllowed)
    end

    it 'invites when both the feature flag and admin token are configured' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')

      client = instance_double(Slack::Web::Client)
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(client)
      allow(client).to receive(:users_admin_invite)

      described_class.invite_to_slack('new.member@example.com', 'Member', 'New')

      expect(client).to have_received(:users_admin_invite).with(
        email: 'new.member@example.com',
        first_name: 'New',
        last_name: 'Member'
      )
    end

    it 'invites a single-channel guest when CHANNEL_NEW_SIGNUPS is configured' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      allow(ENV).to receive(:[]).with('CHANNEL_NEW_SIGNUPS').and_return('#new-signups')
      allow(described_class).to receive(:find_channel_id)
        .with('#new-signups')
        .and_return('C123')

      client = instance_double(Slack::Web::Client)
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(client)
      allow(client).to receive(:users_admin_invite)

      described_class.invite_to_slack('new.member@example.com', 'Member', 'New')

      expect(client).to have_received(:users_admin_invite).with(
        email: 'new.member@example.com',
        first_name: 'New',
        last_name: 'Member',
        channels: 'C123',
        ultra_restricted: true
      )
      expect(described_class.new_signup_invite_mode).to eq('single_channel_guest')
    end
  end

  describe '.channel_member? and .kick_from_channel' do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ENV').and_return('production')
    end

    it 'resolves a channel name to an ID before checking membership' do
      client = double('Slack client')
      allow(described_class).to receive(:client).and_return(client)
      allow(described_class).to receive(:find_channel_id).with('#band-saw-users').and_return('CBANDSAW')
      allow(client).to receive(:conversations_members)
        .with(channel: 'CBANDSAW', limit: 1_000, cursor: nil)
        .and_return(double(members: ['UADA'], response_metadata: nil))

      expect(described_class.channel_member?('#band-saw-users', 'UADA')).to be(true)
    end

    it 'skips resolution and uses the value directly when it is already a channel ID' do
      client = double('Slack client')
      allow(described_class).to receive(:client).and_return(client)
      expect(described_class).not_to receive(:find_channel_id)
      allow(client).to receive(:conversations_members)
        .with(channel: 'C0123456789', limit: 1_000, cursor: nil)
        .and_return(double(members: [], response_metadata: nil))

      expect(described_class.channel_member?('C0123456789', 'UADA')).to be(false)
    end

    it 'resolves a channel name to an ID before kicking a member' do
      client = double('Slack client')
      allow(described_class).to receive(:client).and_return(client)
      allow(described_class).to receive(:find_channel_id).with('#band-saw-users').and_return('CBANDSAW')
      allow(client).to receive(:conversations_kick)

      described_class.kick_from_channel('#band-saw-users', 'UADA')

      expect(client).to have_received(:conversations_kick).with(channel: 'CBANDSAW', user: 'UADA')
    end

    it 'falls back to the raw value when a channel name cannot be resolved' do
      client = double('Slack client')
      allow(described_class).to receive(:client).and_return(client)
      allow(described_class).to receive(:find_channel_id).with('#missing-channel').and_return(nil)
      allow(client).to receive(:conversations_kick)

      described_class.kick_from_channel('#missing-channel', 'UADA')

      expect(client).to have_received(:conversations_kick).with(channel: '#missing-channel', user: 'UADA')
    end

    it 'raises a clear, actionable error naming the channel when the bot is not a member of it' do
      client = double('Slack client')
      allow(described_class).to receive(:client).and_return(client)
      allow(described_class).to receive(:find_channel_id).with('#band-saw-users').and_return('CBANDSAW')
      allow(client).to receive(:conversations_kick)
        .and_raise(Slack::Web::Api::Errors::NotInChannel.new('not_in_channel'))

      expect { described_class.kick_from_channel('#band-saw-users', 'UADA') }
        .to raise_error(/Bot not in channel #band-saw-users/)
    end
  end

  describe '.promote_to_regular' do
    it 'posts to the legacy administrative endpoint' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      client = instance_double(Slack::Web::Client)
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(client)
      allow(client).to receive(:post)

      described_class.promote_to_regular('U123')

      expect(client).to have_received(:post).with('users.admin.setRegular', user: 'U123')
    end
  end
end
