module Service
  module SlackChannelAssignment
    def self.resolve!(channels, actor = nil)
      failures = []

      resolved_channels = channels.each_with_object({}) do |(field, value), resolved|
        name = Service::SlackChannelCache.normalize_name(value)
        next if name.blank?

        channel_id = find_channel_id(name)
        unless channel_id.present?
          Rails.logger.warn(
            "[SlackChannelAssignment] resolution failed field=#{field} channel=#{name.inspect}"
          )
          failures << name
          next
        end

        resolved[field.to_s] = { id: channel_id, name: name }
      rescue Slack::Web::Api::Errors::SlackError => error
        bot_channel_not_found = error if error.is_a?(Slack::Web::Api::Errors::ChannelNotFound)
        Rails.logger.warn(
          "[SlackChannelAssignment] resolution failed field=#{field} " \
          "channel=#{name.inspect} error=#{error.class}"
        )
        failures << name
      end

      report_unresolved_channels(failures, actor) if failures.any?
      resolved_channels
    end

    def self.find_channel_id(channel_name)
      bot_channel_not_found = nil
      channel_id = begin
        Service::SlackConnector.find_channel_id(
          channel_name,
          on_channel_not_found: ->(error) { bot_channel_not_found = error }
        )
      rescue Slack::Web::Api::Errors::SlackError => error
        bot_channel_not_found = error if error.is_a?(Slack::Web::Api::Errors::ChannelNotFound)
        Rails.logger.warn(
          "[SlackChannelAssignment] bot channel resolution failed " \
          "channel=#{channel_name.inspect} error=#{error.class}; retrying with admin token"
        )
        nil
      end

      return channel_id if channel_id.present?

      admin_channel_id = begin
        find_channel_id_with_admin(channel_name)
      rescue Slack::Web::Api::Errors::ChannelNotFound
        raise
      rescue
        report_deferred_channel_not_found(channel_name, bot_channel_not_found)
        raise
      end
      return admin_channel_id if admin_channel_id.present?

      report_deferred_channel_not_found(channel_name, bot_channel_not_found)
      nil
    rescue Slack::Web::Api::Errors::ChannelNotFound => error
      operation = Service::SlackChannelCache.channel_id?(channel_name) ?
        'conversations.info admin channel resolution' :
        'conversations.list admin channel resolution'
      Service::SlackConnector.report_channel_not_found(channel_name, error, operation: operation)
      nil
    end

    def self.report_deferred_channel_not_found(channel_name, error)
      return unless error

      operation = Service::SlackChannelCache.channel_id?(channel_name) ?
        'conversations.info' : 'conversations.list'
      Service::SlackConnector.report_channel_not_found(channel_name, error, operation: operation)
    end

    def self.find_channel_id_with_admin(channel_name)
      client = Service::SlackConnector.admin_client('conversations.list')
      return nil unless client

      if Service::SlackChannelCache.channel_id?(channel_name)
        response = Service::SlackConnector.with_rate_limit_retry(
          'conversations.info admin channel resolution'
        ) { client.conversations_info(channel: channel_name) }
        channel = response.channel
        if channel.respond_to?(:is_archived) && channel.is_archived
          return nil
        end
        Service::SlackChannelCache.store(id: channel.id.to_s, name: channel.name.to_s)
        return channel.id.to_s
      end

      cursor = nil
      loop do
        response = Service::SlackConnector.with_rate_limit_retry(
          'conversations.list admin channel resolution'
        ) do
          client.conversations_list(
            types: 'public_channel,private_channel',
            exclude_archived: true,
            limit: 200,
            cursor: cursor
          )
        end
        channel = Array(response.channels).find do |candidate|
          Service::SlackChannelCache.normalize_name(candidate.name) == channel_name
        end
        if channel
          Service::SlackChannelCache.store(id: channel.id.to_s, name: channel.name.to_s)
          return channel.id.to_s
        end

        cursor = response.response_metadata&.next_cursor.to_s
        break if cursor.blank?
      end
      nil
    end

    def self.invite_bot_or_notify(resolved_channels, actor)
      return if resolved_channels.blank?

      bot_user_id = nil
      failures = resolved_channels.values.filter_map do |channel|
        begin
          next if bot_in_channel?(channel[:id])

          Service::SlackConnector.client.conversations_join(channel: channel[:id])
          nil
        rescue => error
          Rails.logger.warn(
            "[SlackChannelAssignment] bot join failed channel_id=#{channel[:id]} " \
            "error=#{error.class}"
          )
          invite_bot_with_admin(channel) ? nil : channel
        end
      end
      bot_user_id = Service::SlackConnector.client.auth_test.user_id.to_s if failures.any?
      notify_actor(failures, actor, bot_user_id) if failures.any?
    rescue => error
      Rails.logger.warn("[SlackChannelAssignment] bot invitation unavailable error=#{error.class}")
      notify_actor(resolved_channels.values, actor, bot_user_id)
    end

    def self.bot_in_channel?(channel_id)
      response = Service::SlackConnector.client.conversations_info(channel: channel_id)
      response.channel.respond_to?(:is_member) && response.channel.is_member
    rescue Slack::Web::Api::Errors::SlackError => error
      Rails.logger.warn(
        "[SlackChannelAssignment] bot membership check failed channel_id=#{channel_id} " \
        "error=#{error.class}; attempting join"
      )
      false
    end

    def self.invite_bot_with_admin(channel)
      admin_client = Service::SlackConnector.admin_client('conversations.invite')
      return false unless admin_client

      bot_user_id = Service::SlackConnector.client.auth_test.user_id.to_s
      return false if bot_user_id.blank?

      admin_client.conversations_invite(channel: channel[:id], users: bot_user_id)
      true
    rescue Slack::Web::Api::Errors::AlreadyInChannel
      true
    rescue => error
      Rails.logger.warn(
        "[SlackChannelAssignment] admin bot invite failed channel=#{channel[:name].inspect} " \
        "channel_id=#{channel[:id]} error=#{error.class}"
      )
      false
    end

    def self.notify_actor(channels, actor, bot_user_id)
      slack_id = actor&.slack_user&.slack_id
      unless slack_id.present?
        Rails.logger.warn(
          "[SlackChannelAssignment] manual invitation reminder could not be delivered " \
          "actor_id=#{actor&.id}"
        )
        return
      end

      mentions = channels.map { |channel| "<##{channel[:id]}>" }.uniq.join(', ')
      bot_reference = bot_user_id.present? ? "<@#{bot_user_id}>" : 'the Member Portal bot'
      Service::SlackConnector.send_slack_message(
        "I could not join #{mentions} automatically. Please manually invite #{bot_reference} " \
        "to #{channels.one? ? 'that channel' : 'those channels'}.",
        slack_id
      )
    rescue => error
      Rails.logger.warn(
        "[SlackChannelAssignment] manual invitation reminder failed " \
        "actor_id=#{actor&.id} error=#{error.class}"
      )
    end

    def self.report_unresolved_channels(names, actor)
      Rails.logger.warn(
        "[SlackChannelAssignment] unresolved channels=#{names.inspect} actor_id=#{actor&.id}"
      )
      Honeybadger.notify(
        "Slack channel(s) could not be resolved",
        context: { channels: names, actor_id: actor&.id.to_s }
      ) if defined?(Honeybadger)

      slack_id = actor&.slack_user&.slack_id
      return if slack_id.blank?

      mentions = names.map { |name| display_name(name) }.uniq.join(', ')
      Service::SlackConnector.send_slack_message(
        "I couldn't verify #{names.one? ? 'this Slack channel' : 'these Slack channels'}: #{mentions}. " \
        "The change was saved, but Slack notifications for #{names.one? ? 'it' : 'them'} may not work until this is fixed.",
        slack_id
      )
    rescue => error
      Rails.logger.warn(
        "[SlackChannelAssignment] unresolved-channel notice failed " \
        "actor_id=#{actor&.id} error=#{error.class}"
      )
    end

    def self.display_name(name)
      name
    end

    private_class_method :find_channel_id, :find_channel_id_with_admin, :bot_in_channel?,
      :invite_bot_with_admin, :notify_actor,
      :report_unresolved_channels, :report_deferred_channel_not_found, :display_name
  end
end
