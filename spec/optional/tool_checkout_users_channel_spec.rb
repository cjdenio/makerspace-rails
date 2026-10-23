require 'rails_helper'

if ENV['RUN_OPTIONAL_SLACK_CHECKOUT_SPECS'] == 'true'
  RSpec.describe ToolCheckout do
    let(:member) { create(:member, firstname: 'Ada', lastname: 'Lovelace') }
    let(:shop) { Shop.create!(name: 'Wood Shop') }
    let(:tool) do
      Tool.create!(
        name: 'Band Saw',
        shop: shop,
        announce: true,
        announce_channel: 'band-saw-users',
        users_channel: 'band-saw-users'
      )
    end

    it 'does not invite a member who is already in the tool users channel' do
      SlackUser.create!(member: member, slack_id: 'UADA')
      allow(Service::SlackConnector).to receive(:channel_member?).and_return(true)
      allow(Service::SlackConnector).to receive(:invite_to_channel)

      checkout = described_class.create!(member: member, tool: tool)

      expect(Service::SlackConnector).not_to have_received(:invite_to_channel)
      expect(checkout.checkout_success_message).to include('<@UADA>')
    end

    it 'warns that a Slack member must be manually invited after both invite attempts fail' do
      SlackUser.create!(member: member, slack_id: 'UADA')
      allow(Service::SlackConnector).to receive(:channel_member?).and_return(false)
      allow(Service::SlackConnector).to receive(:invite_to_channel).and_raise(StandardError, 'bot invite failed')
      fallback_client = double('Slack client')
      allow(Service::SlackConnector).to receive(:client).and_return(fallback_client)
      allow(fallback_client).to receive(:conversations_invite).and_raise(StandardError, 'fallback invite failed')

      checkout = described_class.create!(member: member, tool: tool)

      expect(checkout.checkout_success_message).to include(
        'please manually invite <@UADA> to #band-saw-users'
      )
    end

    it 'sends one checkout announcement when announce and users channels are the same' do
      SlackUser.create!(member: member, slack_id: 'UADA')
      allow(Service::SlackConnector).to receive(:channel_member?).and_return(true)
      allow(Service::SlackConnector).to receive(:send_slack_message)
      checkout = described_class.create!(member: member, tool: tool)

      checkout.announce_checkout_success

      expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
        a_string_including('<@UADA> (Ada Lovelace) has been checked out on *Band Saw*'),
        '#band-saw-users'
      )
    end

    it 'explains that a member without Slack cannot be added to the users channel' do
      checkout = described_class.create!(member: member, tool: tool)

      expect(checkout.checkout_success_message).to include(
        'Ada Lovelace is not yet on Slack, so could not add them to #band-saw-users'
      )
    end

    it 'displays exactly one channel prefix for legacy and normalized channel names' do
      checkout = described_class.create!(member: member, tool: tool)

      expect(checkout.checkout_success_message).to include('to #band-saw-users')
      expect(checkout.checkout_success_message).not_to include('to ##band-saw-users')

      tool.set(users_channel: 'band-saw-users')

      expect(checkout.checkout_success_message).to include('to #band-saw-users')
      expect(checkout.checkout_success_message).not_to include('to ##band-saw-users')
    end
  end
end
