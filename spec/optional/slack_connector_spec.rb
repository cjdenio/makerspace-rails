require 'rails_helper'

if ENV['RUN_OPTIONAL_SLACK_CHECKOUT_SPECS'] == 'true'
  RSpec.describe Service::SlackConnector do
    describe '.invite_to_channel' do
      it 'logs failures to Rails and the Slack logs channel before re-raising' do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
        client = double('Slack client')
        allow(described_class).to receive(:client).and_return(client)
        allow(described_class).to receive(:find_channel_id).and_return('CBANDSAW')
        allow(client).to receive(:conversations_invite).and_raise(StandardError, 'missing_scope')
        allow(described_class).to receive(:send_slack_message)
        allow(Rails.logger).to receive(:error)

        expect { described_class.invite_to_channel('band-saw-users', 'UADA') }
          .to raise_error(StandardError, 'missing_scope')

        expect(Rails.logger).to have_received(:error).with(
          a_string_including('[SlackChannelInviteFailed]', 'band-saw-users', 'UADA')
        )
        expect(described_class).to have_received(:send_slack_message).with(
          a_string_including('[SlackChannelInviteFailed]', 'band-saw-users', 'UADA'),
          described_class.logs_channel
        )
      end
    end
  end
end
