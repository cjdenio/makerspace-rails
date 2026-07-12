require 'rails_helper'

RSpec.describe Service::MemberAccess do
  describe '.revoke_slack_access' do
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
end
