# Exercise actual channel helpers and default delivery without Rails or Slack:
# ruby -r rspec/autorun spec/unit/slack_channel_semantics_spec.rb
require 'active_support/all'
require 'slack-ruby-client'
require_relative '../../lib/service/slack_connector'
require_relative '../../app/services/fix_ticket_delivery'

RSpec.describe 'Slack staff channel semantics' do
  let(:settings) { {} }
  let(:client) { double('Slack client', chat_postMessage: { 'ts' => '123.456' }) }
  let(:redis) { double('Redis', set: 'OK') }

  before do
    stub_const('SystemConfig', Class.new do
      def self.get(_key); end
      def self.slack_tickets_channel; end
    end)
    stub_const('Rails', Module.new do
      def self.env; ActiveSupport::StringInquirer.new('production'); end
    end)
    stub_const('Current', Module.new do
      def self.request_id; 'channel-test'; end
    end)
    stub_const('REDIS', redis)
    allow(SystemConfig).to receive(:get) { |key| settings[key] }
    allow(Service::SlackConnector).to receive(:client).and_return(client)
  end

  around do |example|
    previous_slack_env = ENV['SLACK_ENV']
    ENV['SLACK_ENV'] = 'production'
    example.run
  ensure
    ENV['SLACK_ENV'] = previous_slack_env
  end

  [nil, '', '  '].each do |missing_value|
    it "uses separate channel defaults for unset or blank settings: #{missing_value.inspect}" do
      settings['slack_channel_rm'] = missing_value
      settings['slack_channel_admin'] = missing_value
      expect(Service::SlackConnector.resource_managers_channel).to eq('resource_managers')
      expect(Service::SlackConnector.members_relations_channel).to eq('members_relations')
      expect(Service::SlackConnector.admin_channel).to eq('members_relations')
    end
  end

  it 'uses the resource manager setting independently from the members relations setting' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
    expect(Service::SlackConnector.resource_managers_channel).to eq('CRESOURCE')
    expect(Service::SlackConnector.members_relations_channel).to eq('CMEMBERS')
    expect(Service::SlackConnector.admin_channel).to eq('CMEMBERS')
    settings['slack_channel_rm'] = 'COTHERRESOURCE'
    expect(Service::SlackConnector.members_relations_channel).to eq('CMEMBERS')
  end

  it 'posts existing default operational messages to the members relations setting' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
    Service::SlackConnector.send_slack_message('Payment received')
    expect(client).to have_received(:chat_postMessage).with(hash_including(
      channel: 'CMEMBERS', text: 'Payment received'))
  end

  it 'keeps instance delivery helpers on the members relations destination' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
    sender = Class.new { include Service::SlackConnector }.new
    sender.send_slack_message('Subscription cancelled')
    expect(client).to have_received(:chat_postMessage).with(hash_including(
      channel: 'CMEMBERS', text: 'Subscription cancelled'))
  end

  it 'queues implicit default messages for members relations rather than resource managers' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
    Service::SlackConnector.enque_message('Refund completed')
    expect(redis).to have_received(:set) do |_key, payload|
      expect(JSON.parse(payload)).to include('channel' => 'CMEMBERS', 'message' => 'Refund completed')
    end
  end

  it 'leaves explicit treasurer and logs destinations separate' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS',
      'slack_channel_treasurer' => 'CFINANCE', 'slack_channel_logs' => 'CLOGS')
    Service::SlackConnector.send_slack_message('Invoice review', Service::SlackConnector.treasurer_channel)
    Service::SlackConnector.send_slack_message('Integration error', Service::SlackConnector.logs_channel)
    expect(client).to have_received(:chat_postMessage).with(hash_including(channel: 'CFINANCE'))
    expect(client).to have_received(:chat_postMessage).with(hash_including(channel: 'CLOGS'))
  end

  it 'routes shop-unassigned repair staff notifications to resource managers' do
    settings.merge!('slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
    stub_const('FixTicketPresenter', Module.new do
      def self.event_actor(_event, _ticket); 'Reporter'; end
      def self.event_changes(_event); {}; end
    end)
    ticket = double(id: 17, title: 'Broken lathe', announce_to_slack: false)
    event = double(kind: 'note', note: 'Needs review', unscoped_staff_notification: true,
      central_enabled: false, recipients: [], set: nil)
    allow(SystemConfig).to receive(:slack_tickets_channel).and_return('')
    allow(FixTicketDelivery).to receive(:url).and_return('https://example.test/fix-tickets/17')
    allow(FixTicketDelivery).to receive(:publish)
    allow(Service::SlackConnector).to receive(:resolved_channel_id).with('CRESOURCE').and_return('CRESOURCE')

    FixTicketDelivery.call(ticket, event)

    expect(FixTicketDelivery).to have_received(:publish).with(event, 'unscoped-staff', 'CRESOURCE',
      a_string_including('Broken lathe', 'Needs review'))
  end
end
