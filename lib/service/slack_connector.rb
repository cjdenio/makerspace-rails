module Service
  module SlackConnector
    mattr_accessor :slack_team_id

    def enque_message(
        message,
        channel = ::Service::SlackConnector.members_relations_channel,
        uniquifier = ::Service::SlackConnector.request_caller_id(caller_locations(1,1)[0].label)
      )
      ::Service::SlackConnector.enque_message(message, channel, uniquifier)
    end
    def self.enque_message(
        message,
        channel = members_relations_channel,
        uniquifier = request_caller_id(caller_locations(1,1)[0].label)
      )
      REDIS.set(uniquifier, {
        message: message,
        channel: channel,
        timestamp: Time.now
      }.to_json)
    end
    def get_enqueued_messages(uniquifier)
      ::Service::SlackConnector.get_enqueued_messages(uniquifier)
    end
    def self.get_enqueued_messages(uniquifier)
      related_keys = REDIS.keys(uniquifier)
      related_keys.reduce({}) { |msg_hash, key| msg_hash.merge({ key => REDIS.get(key) }) }
    end
    def send_slack_messages(messages, channel = ::Service::SlackConnector.members_relations_channel)
      ::Service::SlackConnector.send_slack_messages(messages, channel)
    end
    def self.send_slack_messages(messages, channel = ::Service::SlackConnector.members_relations_channel)
      send_slack_message(format_slack_messages(messages, channel), channel) unless messages.nil? || messages.empty? || Rails.env.test?
    end
    def send_slack_message(message, channel = ::Service::SlackConnector.members_relations_channel)
      ::Service::SlackConnector.send_slack_message(message, channel)
    end
    def self.send_slack_message(message, channel = ::Service::SlackConnector.members_relations_channel)
      return if Rails.env.test?
      send_as_msg = message.kind_of?(String)
      begin
        if send_as_msg
          client.chat_postMessage(
            channel: safe_channel(channel),
            text: message,
            as_user: false,
            username: 'MemberPortalBot',
            icon_emoji: ':ghost:'
          )
        else
          client.chat_postMessage(
            channel: safe_channel(channel),
            blocks: message,
            as_user: false,
            username: 'MemberPortalBot',
            icon_emoji: ':ghost:'
          )
        end
      rescue Slack::Web::Api::Errors::SlackError
        begin
          if send_as_msg
            client.chat_postMessage(
              channel: safe_channel(channel),
              text: message
            )
          else
            client.chat_postMessage(
              channel: safe_channel(channel),
              blocks: message
            )
          end
        rescue Slack::Web::Api::Errors::SlackError => e
          raise e
        end
      end
    end
    def self.update_slack_message(channel, ts, message)
      return if Rails.env.test?
      client.chat_update(channel: safe_channel(channel), ts: ts, text: message)
    end
    def self.pin_slack_message(channel, ts)
      return if Rails.env.test?
      return if ts.blank?

      client.pins_add(channel: safe_channel(channel), timestamp: ts)
    end
    def self.delete_slack_message(channel, ts)
      return if Rails.env.test?
      client.chat_delete(channel: safe_channel(channel), ts: ts)
    end
    def self.invite_to_channel(channel, slack_id)
      return if Rails.env.test?
      client.conversations_invite(channel: safe_channel(channel), users: slack_id)
    end
    def self.kick_from_channel(channel, slack_id)
      return if Rails.env.test?
      client.conversations_kick(channel: safe_channel(channel), user: slack_id)
    end
    def self.init_team_id
      self.slack_team_id = ENV['SLACK_TEAM_ID'].presence
      return slack_team_id if slack_team_id.present?
      return if Rails.env.test?

      response = client.team_info
      self.slack_team_id = response.team.id if response.respond_to?(:team) && response.team.respond_to?(:id)
      Rails.logger.warn("Slack team id could not be determined") if slack_team_id.blank?
      slack_team_id
    rescue => e
      Rails.logger.warn("Slack team id could not be determined: #{e.message}")
      nil
    end
    def self.team_id
      slack_team_id.presence || init_team_id
    end
    def self.slack_user_url(slack_id)
      id = team_id
      return nil if id.blank? || slack_id.blank?
      "slack://user?team=#{id}&id=#{slack_id}"
    end
    def invite_to_slack(email, lastname, firstname)
      ::Service::SlackConnector.invite_to_slack(email, lastname, firstname)
    end
    def self.invite_to_slack(email, lastname, firstname)
      unless ENV['SLACK_INVITES_ENABLED'] == 'true'
        raise Error::NotAllowed.new('Slack invites are not enabled in this environment')
      end
      client.users_admin_invite(
        email: email,
        first_name: firstname,
        last_name: lastname
      )
    end

    # ── Channel helpers ──────────────────────────────────────────────────────
    # All channels read from SystemConfig first, with hardcoded fallback.
    # Configure channel names (without #) in Admin → Settings → Slack.

    def self.treasurer_channel
      SystemConfig.get('slack_channel_treasurer') || 'treasurer'
    end

    def self.members_relations_channel
      SystemConfig.get('slack_channel_rm') || 'members_relations'
    end

    def self.logs_channel
      SystemConfig.get('slack_channel_logs') || 'interface-logs'
    end

    def self.admin_channel
      SystemConfig.get('slack_channel_admin') || 'general'
    end

    private
    def self.safe_channel(channel)
      ENV['SLACK_ENV'] == 'production' ? channel : 'test_channel'
    end
    def self.client
      Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])
    end
    def self.format_slack_messages(messages, channel)
      messages = messages.map { |m| "#{channel}| #{m}" } unless ENV['SLACK_ENV'] == 'production'
      messages.join(" \n ")
    end
    def self.request_caller_id(caller_method)
      "#{Current.request_id}.#{caller_method}"
    end
  end
end
