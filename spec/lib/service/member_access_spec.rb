require 'rails_helper'

RSpec.describe Service::MemberAccess do
  describe '.revoke_slack_access' do
    before do
      allow(Honeybadger).to receive(:notify) if defined?(Honeybadger)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_BOT_TOKEN').and_return(nil)
    end

    it 'alerts and pins a manual revocation message when the Slack admin token is missing' do
      member = create(:member, firstname: 'Revoked', lastname: 'Member')
      SlackUser.create!(member: member, slack_id: 'U_REVOKED')
      response = double('SlackResponse', ts: '123.456')

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
      allow(Service::SlackConnector).to receive(:pin_slack_message)

      result = described_class.revoke_slack_access(member)

      expect(result).to eq(status: :skipped, reason: 'SLACK_ADMIN_TOKEN not configured')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /<!channel>.*Revoked Member.*U_REVOKED.*must be manually disabled by an admin.*SLACK_ADMIN_TOKEN not configured/,
        Service::SlackConnector.admin_channel
      )
      expect(Service::SlackConnector).to have_received(:pin_slack_message).with(Service::SlackConnector.admin_channel, '123.456')
    end

    it 'alerts and pins a manual revocation message when Slack deactivation fails' do
      member = create(:member, firstname: 'Revoked', lastname: 'Member')
      response = double('SlackResponse', ts: '789.012')
      slack_client = instance_double(Slack::Web::Client)
      slack_user = OpenStruct.new(user: OpenStruct.new(id: 'U_LOOKUP'))

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(slack_client)
      allow(slack_client).to receive(:users_lookupByEmail).with(email: member.email).and_return(slack_user)
      allow(slack_client).to receive(:users_admin_setInactive).with(user: 'U_LOOKUP').and_raise(StandardError.new('inactive failed'))
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
      allow(Service::SlackConnector).to receive(:pin_slack_message)

      result = described_class.revoke_slack_access(member)

      expect(result).to eq(status: :error, message: 'inactive failed')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /<!channel>.*Revoked Member.*U_LOOKUP.*must be manually disabled by an admin.*inactive failed/,
        Service::SlackConnector.admin_channel
      )
      expect(Service::SlackConnector).to have_received(:pin_slack_message).with(Service::SlackConnector.admin_channel, '789.012')
    end

    it 'uses the bot token for lookup and the admin token for deactivation' do
      member = create(:member, firstname: 'Revoked', lastname: 'Member')
      bot_client = instance_double(Slack::Web::Client)
      admin_client = instance_double(Slack::Web::Client)
      slack_user = OpenStruct.new(user: OpenStruct.new(id: 'U_LOOKUP'))

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_BOT_TOKEN').and_return('bot-token')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      allow(Slack::Web::Client).to receive(:new)
        .with(token: 'bot-token')
        .and_return(bot_client)
      allow(Slack::Web::Client).to receive(:new)
        .with(token: 'admin-token')
        .and_return(admin_client)
      allow(bot_client).to receive(:users_lookupByEmail)
        .with(email: member.email)
        .and_return(slack_user)
      allow(admin_client).to receive(:users_admin_setInactive)
        .with(user: 'U_LOOKUP')

      result = described_class.revoke_slack_access(member)

      expect(result).to eq(
        status: :ok,
        message: "Deactivated Slack user for #{member.email}"
      )
      expect(bot_client).to have_received(:users_lookupByEmail)
      expect(admin_client).to have_received(:users_admin_setInactive)
    end


    it 'falls back to deactivating the stored Slack ID when email lookup misses' do
      member = create(:member, firstname: 'Revoked', lastname: 'Member')
      SlackUser.create!(member: member, slack_id: 'U_STORED')
      slack_client = instance_double(Slack::Web::Client)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(slack_client)
      allow(slack_client).to receive(:users_lookupByEmail).with(email: member.email).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('users_not_found'))
      allow(slack_client).to receive(:users_admin_setInactive).with(user: 'U_STORED')
      allow(Service::SlackConnector).to receive(:send_slack_message)
      allow(Service::SlackConnector).to receive(:pin_slack_message)

      result = described_class.revoke_slack_access(member)

      expect(result).to eq(status: :ok, message: "Deactivated stored Slack user U_STORED for #{member.email}")
      expect(slack_client).to have_received(:users_admin_setInactive).with(user: 'U_STORED')
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'alerts and pins when stored Slack ID fallback deactivation fails' do
      member = create(:member, firstname: 'Revoked', lastname: 'Member')
      SlackUser.create!(member: member, slack_id: 'U_STORED')
      response = double('SlackResponse', ts: '234.567')
      slack_client = instance_double(Slack::Web::Client)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(slack_client)
      allow(slack_client).to receive(:users_lookupByEmail).with(email: member.email).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('users_not_found'))
      allow(slack_client).to receive(:users_admin_setInactive).with(user: 'U_STORED').and_raise(StandardError.new('stored inactive failed'))
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
      allow(Service::SlackConnector).to receive(:pin_slack_message)

      result = described_class.revoke_slack_access(member)

      expect(result).to eq(status: :error, message: 'stored inactive failed')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /<!channel>.*Revoked Member.*U_STORED.*must be manually disabled by an admin.*stored inactive failed/,
        Service::SlackConnector.admin_channel
      )
      expect(Service::SlackConnector).to have_received(:pin_slack_message).with(Service::SlackConnector.admin_channel, '234.567')
    end
  end

  describe '.full_deprovision' do
    it 'cancels a live subscription, revokes access, silences emails, and rotates the session token' do
      member = create(:member, subscription_id: 'sub-123')
      original_session_token = member.session_token
      gateway = double('gateway')

      allow(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
      allow(BraintreeService::Subscription).to receive(:cancel)
      allow(described_class).to receive(:revoke)

      described_class.full_deprovision(member)

      expect(BraintreeService::Subscription).to have_received(:cancel).with(gateway, 'sub-123')
      expect(described_class).to have_received(:revoke).with(member)
      expect(member.reload.silence_emails).to be true
      expect(member.reload.session_token).not_to eq(original_session_token)
    end

    it 'skips subscription cancellation when there is no subscription_id' do
      member = create(:member, subscription_id: nil)
      allow(described_class).to receive(:revoke)
      allow(BraintreeService::Subscription).to receive(:cancel)

      described_class.full_deprovision(member)

      expect(BraintreeService::Subscription).not_to have_received(:cancel)
    end

    it 'alerts instead of raising when subscription cancellation fails' do
      member = create(:member, subscription_id: 'sub-456')
      allow(Service::BraintreeGateway).to receive(:connect_gateway).and_return(double('gateway'))
      allow(BraintreeService::Subscription).to receive(:cancel).and_raise(StandardError.new('braintree down'))
      allow(described_class).to receive(:revoke)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      expect { described_class.full_deprovision(member) }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /Error cancelling subscription.*braintree down/,
        Service::SlackConnector.logs_channel
      )
    end
  end

  describe '.revoke_gdrive_folder' do
    let(:member) { create(:member, firstname: 'Revoked', lastname: 'Member') }
    let(:drive) { instance_double(Google::Apis::DriveV3::DriveService) }

    before do
      allow(Honeybadger).to receive(:notify) if defined?(Honeybadger)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
    end

    it 'passes supports_all_drives on list_permissions' do
      allow(drive).to receive(:list_permissions).and_return(
        OpenStruct.new(permissions: [])
      )

      described_class.revoke_gdrive_folder(member, 'shared-drive-folder', 'Resources (reader)')

      expect(drive).to have_received(:list_permissions).with(
        'shared-drive-folder',
        fields: 'permissions(id,emailAddress,role)',
        supports_all_drives: true
      )
    end

    it 'passes supports_all_drives on delete_permission when a permission is found and removed' do
      permission = OpenStruct.new(id: 'perm-1', email_address: member.email, role: 'reader')
      allow(drive).to receive(:list_permissions).and_return(OpenStruct.new(permissions: [permission]))
      allow(drive).to receive(:delete_permission)

      result = described_class.revoke_gdrive_folder(member, 'shared-drive-folder', 'Resources (reader)')

      expect(drive).to have_received(:delete_permission).with('shared-drive-folder', 'perm-1', supports_all_drives: true)
      expect(result).to eq(status: :ok, message: 'Removed reader permission from Resources (reader)')
    end

    it 'alerts and pins instead of failing silently when the Drive API errors' do
      response = double('SlackResponse', ts: '345.678')
      allow(drive).to receive(:list_permissions).and_raise(StandardError.new('shared drive lookup failed'))
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
      allow(Service::SlackConnector).to receive(:pin_slack_message)

      result = described_class.revoke_gdrive_folder(member, 'shared-drive-folder', 'Resources (reader)')

      expect(result).to eq(status: :error, message: 'shared drive lookup failed')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /<!channel>.*Revoked Member.*Resources \(reader\).*must be manually removed by an admin.*shared drive lookup failed/,
        Service::SlackConnector.admin_channel
      )
      expect(Service::SlackConnector).to have_received(:pin_slack_message).with(Service::SlackConnector.admin_channel, '345.678')
      if defined?(Honeybadger)
        expect(Honeybadger).to have_received(:notify).with(
          anything,
          hash_including(context: hash_including(member_id: member.id.to_s, member_email: member.email, label: 'Resources (reader)'))
        )
      end
    end

    it 'does not alert when the folder env var is not configured' do
      allow(Service::SlackConnector).to receive(:send_slack_message)

      result = described_class.revoke_gdrive_folder(member, nil, 'Resources (reader)')

      expect(result).to eq(status: :skipped, reason: 'Resources (reader) folder env var not configured')
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(Service::GoogleDrive).not_to have_received(:load_gdrive)
    end
  end
end
