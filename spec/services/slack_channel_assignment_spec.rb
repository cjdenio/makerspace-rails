require 'rails_helper'

RSpec.describe Service::SlackChannelAssignment do
  describe '.resolve!' do
    before do
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
    end

    it 'resolves normalized channel names through the cache-aware connector' do
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#wood-shop', on_channel_not_found: kind_of(Proc)).and_return('C12345678')

      expect(described_class.resolve!(users_channel: '  #Wood-Shop ')).to eq(
        'users_channel' => { id: 'C12345678', name: '#wood-shop' }
      )
    end

    it 'fails open instead of raising when Slack cannot resolve a channel, and does not save it' do
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      expect(described_class.resolve!(announce_channel: 'missing-channel')).to eq({})
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'notifies the actor about channels that could not be resolved, without raising' do
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)
      slack_user = double(slack_id: 'UACTOR')
      actor = double(id: BSON::ObjectId.new, slack_user: slack_user)

      expect(described_class.resolve!({ announce_channel: 'missing-channel' }, actor)).to eq({})
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /couldn't verify this Slack channel: #missing-channel.*change was saved/i,
        'UACTOR'
      )
    end

    it 'resolves the channels it can and skips the ones it cannot, in a single call' do
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#wood-shop', on_channel_not_found: kind_of(Proc)).and_return('C12345678')
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#missing-channel', on_channel_not_found: kind_of(Proc)).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      result = described_class.resolve!(
        users_channel: '#wood-shop',
        announce_channel: 'missing-channel'
      )

      expect(result).to eq('users_channel' => { id: 'C12345678', name: '#wood-shop' })
    end

    it 'uses an admin token to resolve a private channel invisible to the bot, and caches it' do
      admin_client = double('Slack admin client')
      private_channel = double(id: 'G12345678', name: 'officers-private')
      response = double(
        channels: [private_channel],
        response_metadata: double(next_cursor: '')
      )
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#officers-private', on_channel_not_found: kind_of(Proc)).and_return(nil)
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.list').and_return(admin_client)
      expect(admin_client).to receive(:conversations_list).with(
        types: 'public_channel,private_channel',
        exclude_archived: true,
        limit: 200,
        cursor: nil
      ).and_return(response)
      expect(Service::SlackChannelCache).to receive(:store)
        .with(id: 'G12345678', name: 'officers-private')

      expect(described_class.resolve!(announce_channel: '#officers-private')).to eq(
        'announce_channel' => { id: 'G12345678', name: '#officers-private' }
      )
    end

    it 'does not report bot channel_not_found when the admin token resolves the channel' do
      admin_client = double('Slack admin client')
      private_channel = double(id: 'G12345678', name: 'officers-private')
      response = double(channels: [private_channel], response_metadata: double(next_cursor: ''))
      error = Slack::Web::Api::Errors::ChannelNotFound.new(
        'channel_not_found',
        { ok: false, error: 'channel_not_found' }
      )
      allow(Service::SlackConnector).to receive(:find_channel_id) do |_, on_channel_not_found:|
        on_channel_not_found.call(error)
        nil
      end
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.list').and_return(admin_client)
      allow(admin_client).to receive(:conversations_list).and_return(response)
      allow(Service::SlackConnector).to receive(:report_channel_not_found)

      expect(described_class.resolve!(announce_channel: '#officers-private')).to eq(
        'announce_channel' => { id: 'G12345678', name: '#officers-private' }
      )
      expect(Service::SlackConnector).not_to have_received(:report_channel_not_found)
    end

    it 'reports bot channel_not_found after the admin fallback also fails' do
      error = Slack::Web::Api::Errors::ChannelNotFound.new(
        'channel_not_found',
        { ok: false, error: 'channel_not_found' }
      )
      allow(Service::SlackConnector).to receive(:find_channel_id) do |_, on_channel_not_found:|
        on_channel_not_found.call(error)
        nil
      end
      allow(Service::SlackConnector).to receive(:report_channel_not_found)

      expect(described_class.resolve!(announce_channel: '#missing-private')).to eq({})
      expect(Service::SlackConnector).to have_received(:report_channel_not_found).with(
        '#missing-private',
        error,
        operation: 'conversations.list'
      )
    end

    it 'reports the deferred bot response before handling an admin rate-limit error' do
      bot_error = Slack::Web::Api::Errors::ChannelNotFound.new(
        'channel_not_found',
        { ok: false, error: 'channel_not_found' }
      )
      admin_error = Slack::Web::Api::Errors::TooManyRequestsError.new(
        double(headers: { 'retry-after' => '1' })
      )
      allow(Service::SlackConnector).to receive(:find_channel_id) do |_, on_channel_not_found:|
        on_channel_not_found.call(bot_error)
        nil
      end
      allow(described_class).to receive(:find_channel_id_with_admin).and_raise(admin_error)
      allow(Service::SlackConnector).to receive(:report_channel_not_found)

      expect do
        described_class.resolve!(announce_channel: '#missing-private')
      end.to raise_error(admin_error)
      expect(Service::SlackConnector).to have_received(:report_channel_not_found).with(
        '#missing-private',
        bot_error,
        operation: 'conversations.list'
      )
    end

    it 'reports channel_not_found responses returned during admin channel resolution' do
      admin_client = double('Slack admin client')
      response = { ok: false, error: 'channel_not_found', api_key: 'secret-key' }
      error = Slack::Web::Api::Errors::ChannelNotFound.new('channel_not_found', response)
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
      allow(Service::SlackConnector).to receive(:admin_client).and_return(admin_client)
      allow(admin_client).to receive(:conversations_info).and_raise(error)
      allow(Service::SlackConnector).to receive(:report_channel_not_found)

      expect(described_class.resolve!(announce_channel: 'C12345678')).to eq({})
      expect(Service::SlackConnector).to have_received(:report_channel_not_found).with(
        'C12345678',
        error,
        operation: 'conversations.info admin channel resolution'
      )
    end
  end

  describe '.invite_bot_or_notify' do
    let(:client) { double('Slack client') }
    let(:slack_user) { double(slack_id: 'UACTOR') }
    let(:actor) { double(id: BSON::ObjectId.new, slack_user: slack_user) }
    let(:channels) do
      {
        'users_channel' => { id: 'C12345678', name: 'wood-users' }
      }
    end

    before do
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(client).to receive(:conversations_info)
        .and_return(double(channel: double(is_member: false)))
      allow(client).to receive(:auth_test).and_return(double(user_id: 'UBOT'))
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    it 'first attempts to join the channel as the bot' do
      expect(client).to receive(:conversations_info).with(channel: 'C12345678')
      expect(client).to receive(:conversations_join).with(channel: 'C12345678')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'does not join a channel when the bot is already a member' do
      allow(client).to receive(:conversations_info)
        .and_return(double(channel: double(is_member: true)))

      expect(client).not_to receive(:conversations_join)
      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
    end

    it 'DMs the actor rather than failing when the bot cannot be invited' do
      allow(client).to receive(:conversations_join).and_raise(StandardError, 'not allowed')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /could not join <#C12345678>.*manually invite <@UBOT>/i,
        'UACTOR'
      )
    end

    it 'uses an available admin token to invite the bot after join fails' do
      admin_client = double('Slack admin client')
      allow(client).to receive(:conversations_join).and_raise(StandardError, 'not in channel')
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.invite').and_return(admin_client)
      expect(admin_client).to receive(:conversations_invite)
        .with(channel: 'C12345678', users: 'UBOT')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
