# Run without Rails or a Slack connection:
# ruby -r rspec/autorun spec/unit/slack_volunteer_reminder_routing_spec.rb
require 'active_support/all'
require 'slack-ruby-client'
require_relative '../../lib/service/slack_connector'

RSpec.describe 'Slack volunteer reminder receipt routing' do
  let(:client) { double('Slack client') }
  let(:post_response) { { 'ts' => '123.456', 'channel' => 'CTEST' } }

  around do |example|
    previous_slack_env = ENV['SLACK_ENV']
    example.run
  ensure
    ENV['SLACK_ENV'] = previous_slack_env
  end

  before do
    stub_const('Rails', Module.new do
      def self.env; ActiveSupport::StringInquirer.new('production'); end
    end)
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(client).to receive(:chat_postMessage).and_return(post_response)
    allow(client).to receive(:chat_update).and_return({ 'ok' => true })
    allow(client).to receive(:chat_delete).and_return({ 'ok' => true })
  end

  it 'keeps the Admin Channel destination and reports production mode in production' do
    ENV['SLACK_ENV'] = 'production'
    expect(Service::SlackConnector.message_destination_mode).to eq('production')
    expect(Service::SlackConnector.send_slack_message('Pending volunteer claim', 'CADMIN')).to eq(post_response)
    expect(client).to have_received(:chat_postMessage).with(hash_including(channel: 'CADMIN'))
  end

  it 'redirects a nonproduction post to the test channel and retains its returned receipt' do
    ENV['SLACK_ENV'] = 'development'
    expect(Service::SlackConnector.message_destination_mode).to eq('test')
    expect(Service::SlackConnector.send_slack_message('Pending volunteer claim', 'CADMIN')).to eq(post_response)
    expect(client).to have_received(:chat_postMessage).with(hash_including(channel: 'test_channel'))
  end

  it 'updates a resolved receipt in its returned conversation ID during nonproduction' do
    ENV['SLACK_ENV'] = 'development'
    Service::SlackConnector.update_slack_message('CTEST', '123.456', 'Waiting 8 days', resolved_channel: true)
    expect(client).to have_received(:chat_update)
      .with(channel: 'CTEST', ts: '123.456', text: 'Waiting 8 days')
  end

  it 'keeps the existing safe redirect for callers that have not supplied a resolved receipt' do
    ENV['SLACK_ENV'] = 'development'
    Service::SlackConnector.update_slack_message('CADMIN', '123.456', 'Existing caller')
    expect(client).to have_received(:chat_update)
      .with(channel: 'test_channel', ts: '123.456', text: 'Existing caller')
  end

  it 'leaves production resolved receipt IDs unchanged' do
    ENV['SLACK_ENV'] = 'production'
    Service::SlackConnector.update_slack_message('CADMIN', '123.456', 'Approved after 8 days', resolved_channel: true)
    expect(client).to have_received(:chat_update)
      .with(channel: 'CADMIN', ts: '123.456', text: 'Approved after 8 days')
  end

  it 'deletes an extra nonproduction post by its resolved conversation ID' do
    ENV['SLACK_ENV'] = 'development'
    Service::SlackConnector.delete_slack_message('CTEST', '987.654', resolved_channel: true)
    expect(client).to have_received(:chat_delete).with(channel: 'CTEST', ts: '987.654')
  end

  it 'keeps the existing safe redirect for ordinary message deletion' do
    ENV['SLACK_ENV'] = 'development'
    Service::SlackConnector.delete_slack_message('CADMIN', '987.654')
    expect(client).to have_received(:chat_delete).with(channel: 'test_channel', ts: '987.654')
  end
end
