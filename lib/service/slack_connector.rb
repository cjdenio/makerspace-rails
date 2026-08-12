module Service
  module SlackConnector
    mattr_accessor :slack_team_id
    SLACK_RATE_LIMIT_MAX_RETRIES = 5

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
    def self.open_modal(trigger_id, view)
      return if Rails.env.test?
      client.views_open(trigger_id: trigger_id, view: view)
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

    def self.schedule_slack_message(channel:, text:, post_at:)
      with_rate_limit_retry("chat.scheduleMessage") do
        response = client.chat_scheduleMessage(
          channel: safe_channel(channel),
          text: text,
          post_at: post_at.to_i
        )
        response.scheduled_message_id
      end
    end

    def self.delete_scheduled_slack_message(channel:, scheduled_message_id:)
      with_rate_limit_retry("chat.deleteScheduledMessage") do
        client.chat_deleteScheduledMessage(
          channel: safe_channel(channel),
          scheduled_message_id: scheduled_message_id
        )
      end
    end

    def self.find_channel_id(channel_name)
      requested = Service::SlackChannelCache.normalize_name(channel_name)
      return if requested.blank?

      cached = Service::SlackChannelCache.fetch(requested)
      return cached[:id] if cached&.dig(:id).present?

      if Service::SlackChannelCache.channel_id?(requested)
        response = with_rate_limit_retry("conversations.info") do
          client.conversations_info(channel: requested)
        end
        channel = response.channel
        return channel.id unless channel.respond_to?(:is_archived) && channel.is_archived
        return
      end

      cursor = nil
      loop do
        response = with_rate_limit_retry("conversations.list") do
          client.conversations_list(
            types: 'public_channel,private_channel',
            exclude_archived: true,
            limit: 200,
            cursor: cursor
          )
        end
        channel = Array(response.channels).find do |candidate|
          candidate.name.to_s.casecmp?(requested)
        end
        return channel.id if channel

        cursor = response.response_metadata&.next_cursor.to_s
        break if cursor.blank?
      end
      nil
    rescue Slack::Web::Api::Errors::ChannelNotFound
      nil
    end

    def self.create_canvas(title, channel_id: nil)
      with_rate_limit_retry("canvases.create") do
        arguments = { title: title }
        arguments[:channel_id] = channel_id if channel_id.present?
        client.canvases_create(**arguments).canvas_id
      end
    end

    def self.set_canvas_channel_access(canvas_id, channel_id)
      with_rate_limit_retry("canvases.access.set channel read") do
        client.canvases_access_set(
          canvas_id: canvas_id,
          access_level: 'read',
          # slack-ruby-client 2.7.0 does not JSON-encode this array even though
          # Slack expects an array-valued JSON parameter.
          channel_ids: JSON.generate([channel_id])
        )
      end
    end

    def self.set_canvas_user_access(canvas_id, user_ids, access_level:)
      ids = Array(user_ids).map(&:to_s).reject(&:blank?).uniq
      return if ids.empty?

      with_rate_limit_retry("canvases.access.set user #{access_level}") do
        client.canvases_access_set(
          canvas_id: canvas_id,
          access_level: access_level,
          user_ids: JSON.generate(ids)
        )
      end
    end

    def self.replace_canvas(canvas_id, markdown)
      changes = [
        {
          operation: 'replace',
          document_content: {
            type: 'markdown',
            markdown: markdown
          }
        }
      ]
      with_rate_limit_retry("canvases.edit") do
        client.canvases_edit(
          canvas_id: canvas_id,
          # See set_canvas_channel_access: nested Canvas parameters must be
          # explicitly JSON-encoded with the currently bundled Slack client.
          changes: JSON.generate(changes)
        )
      end
    end

    def self.with_rate_limit_retry(operation, max_retries: SLACK_RATE_LIMIT_MAX_RETRIES)
      retries = 0
      begin
        yield
      rescue Slack::Web::Api::Errors::TooManyRequestsError => error
        raise if retries >= max_retries

        retries += 1
        retry_after = error.retry_after.to_i
        message = "[SlackRateLimited] operation=#{operation.inspect} " \
          "retry=#{retries}/#{max_retries} retry_after=#{retry_after}"
        $stderr.puts(message)
        Rails.logger.warn(message)
        sleep(retry_after)
        retry
      end
    end

    def self.format_api_error(error)
      details = "#{error.class}: #{error.message.to_s.gsub(/\s+/, ' ').strip}"
      response = error.respond_to?(:response) ? error.response : nil
      return details if response.nil?

      status = response.respond_to?(:status) ? response.status : nil
      body = response.respond_to?(:body) ? response.body : response
      body = body.to_h if body.respond_to?(:to_h)
      response_text = JSON.generate(body).gsub(/\s+/, ' ').strip
      response_text = response_text.first(4_000)

      [
        details,
        ("http_status=#{status}" if status),
        ("slack_response=#{response_text}" if response_text.present?)
      ].compact.join(" ")
    rescue => formatting_error
      "#{details} response_format_error=#{formatting_error.class}: " \
        "#{formatting_error.message.to_s.gsub(/\s+/, ' ').strip}"
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
    def self.slack_channel_url(channel_id)
      id = team_id
      return nil if id.blank? || channel_id.blank?
      "slack://channel?team=#{id}&id=#{channel_id}"
    end
    def invite_to_slack(email, lastname, firstname)
      ::Service::SlackConnector.invite_to_slack(email, lastname, firstname)
    end

    def self.slack_invites_enabled?
      ENV['SLACK_INVITES_ENABLED'] == 'true' && ENV['SLACK_ADMIN_TOKEN'].present?
    end

    def self.invite_to_slack(email, lastname, firstname)
      unless slack_invites_enabled?
        raise Error::NotAllowed.new('Slack invites are not enabled in this environment')
      end

      slack_client = admin_client("users.admin.invite")
      if slack_client.nil?
        raise Error::NotAllowed.new(
          "SLACK_ADMIN_TOKEN is required to invite Slack users"
        )
      end

      arguments = {
        email: email,
        first_name: firstname,
        last_name: lastname
      }

      if ENV['CHANNEL_NEW_SIGNUPS'].present?
        channel_id = find_channel_id(ENV['CHANNEL_NEW_SIGNUPS'])
        if channel_id.blank?
          raise Error::NotAllowed.new(
            "Slack signup channel #{ENV['CHANNEL_NEW_SIGNUPS'].inspect} could not be found"
          )
        end
        arguments[:channels] = channel_id
        arguments[:ultra_restricted] = true
      end

      slack_client.users_admin_invite(**arguments)
    end

    def self.new_signup_invite_mode
      ENV['CHANNEL_NEW_SIGNUPS'].present? ? 'single_channel_guest' : 'full_member'
    end

    # users.admin.setRegular is part of the same legacy, undocumented API
    # family as the existing invite/deactivation calls and is not exposed as
    # a generated helper by slack-ruby-client.
    def self.promote_to_regular(slack_id)
      slack_client = admin_client("users.admin.setRegular")
      if slack_client.nil?
        raise Error::NotAllowed.new(
          "SLACK_ADMIN_TOKEN is required to promote Slack users"
        )
      end

      slack_client.post('users.admin.setRegular', user: slack_id)
    end

    def self.team_billable_info(user:)
      slack_client = admin_client("team.billableInfo")
      return if slack_client.nil?

      slack_client.team_billableInfo(user: user)
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

    def self.api_token_present?
      ENV['SLACK_BOT_TOKEN'].present? || ENV['SLACK_ADMIN_TOKEN'].present?
    end

    def self.admin_token_present?
      ENV['SLACK_ADMIN_TOKEN'].present?
    end

    # Ordinary calls prefer the least-privileged bot token. The historical
    # admin token remains the fallback when no separate bot token is present.
    def self.client
      token = ENV['SLACK_BOT_TOKEN'].presence || ENV['SLACK_ADMIN_TOKEN'].presence
      Slack::Web::Client.new(token: token)
    end

    # Admin-only calls must never fall back to the bot token.
    def self.admin_client(operation)
      token = ENV['SLACK_ADMIN_TOKEN'].presence
      return Slack::Web::Client.new(token: token) if token

      message = "[SlackAdminTokenRequired] operation=#{operation} " \
        "SLACK_ADMIN_TOKEN is required; SLACK_BOT_TOKEN cannot authorize this API call"
      $stderr.puts(message)
      Rails.logger.error(message)
      if defined?(Honeybadger)
        Honeybadger.notify(
          "Slack admin token required",
          context: {
            operation: operation,
            slack_bot_token_present: ENV['SLACK_BOT_TOKEN'].present?
          }
        )
      end
      nil
    end

    private

    def self.safe_channel(channel)
      ENV['SLACK_ENV'] == 'production' ? channel : 'test_channel'
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
