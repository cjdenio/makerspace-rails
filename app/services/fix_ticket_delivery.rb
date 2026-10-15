class FixTicketDelivery
  REFERENCE_FIELDS = %w[shop_id tool_id].freeze
  CENTRAL_FIELDS = %w[status confirmation assignees announcement_note].freeze
  class << self
    def client
      Thread.current[:fix_delivery_lease]&.call
      Service::SlackConnector.client
    end
    def escape(text) = text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    def url(ticket) = "#{ShortUrl.base_url}/fix-tickets/#{ticket.id}"
    def summary(ticket)
      "Ticket ##{ticket.id}: #{escape(ticket.title)}\n#{ticket.status.tr('_', ' ')} · #{ticket.confirmation.tr('_', ' ')}\n#{escape(ticket.shop&.name)} #{escape(ticket.tool&.name || ticket.uncatalogued_tool)}\n#{ticket.show_identity ? "Submitter: #{escape(FixTicketPresenter.member_label(ticket.reporter_id, ticket))}\n" : ""}#{url(ticket)}"
    end
    def call(ticket, event)
      text = "Ticket ##{ticket.id}: #{escape(ticket.title)}\n"
      text += event.kind == 'created' ? 'A report was opened.' : "#{escape(FixTicketPresenter.event_actor(event, ticket))}: #{event.kind}"
      FixTicketPresenter.event_changes(event).slice(*CENTRAL_FIELDS).each { |key, pair| text += "\n#{escape(key.tr('_', ' '))}: #{escape(Array(pair).last)}" }
      text += "\n#{escape(event.note)}" if event.note.present?
      if event.kind == 'bounty'
        bounty_id = event.field_changes.dig('bounty_id', 1) || ticket.bounty_id
        link = ShortUrl.allocate("/volunteer/tasks/#{bounty_id}", origin: ShortUrl.base_url)[:short_url]
        text += "\nA volunteer bounty is available: #{link}"
      end
      text += "\n#{url(ticket)}"
      if event.unscoped_staff_notification
        channel = Service::SlackConnector.resource_managers_channel
        publish(event, 'unscoped-staff', Service::SlackConnector.resolved_channel_id(channel), text)
      end
      central = SystemConfig.slack_tickets_channel
      if central.present? && event.central_enabled && (%w[created assigned note bounty].include?(event.kind) || (event.kind == 'updated' && (event.note.present? || (event.field_changes.keys & (CENTRAL_FIELDS + REFERENCE_FIELDS)).any?)))
        channel = Service::SlackConnector.resolved_channel_id(central)
        team = ENV['SLACK_TEAM_ID'].presence || Service::SlackConnector.slack_team_id.to_s
        root = root!(ticket, event, channel, team)
        central_text = (event.field_changes.keys & REFERENCE_FIELDS).any? ? "#{text}\n#{summary(ticket)}" : text
        publish(event, 'central', ticket.slack_ticket_channel_id, central_text, thread_ts: root, broadcast: event.kind == 'bounty', namespace: team) unless event.kind == 'created'
      end
      if ticket.announce_to_slack && (event.kind == 'created' || (event.field_changes.keys & %w[title status confirmation announcement_note announce_to_slack shop_id tool_id]).any?)
        channel = ticket.tool&.announce_channel.presence || ticket.tool&.users_channel.presence || ticket.shop&.slack_channel.presence
        # Optional shop announcements must not block participant DMs or later events.
        if channel
          safe = Service::SlackConnector.resolved_channel_id(channel)
          if central.blank? || safe != Service::SlackConnector.resolved_channel_id(central)
            publish(event, 'shop', safe, "#{summary(ticket)}\n#{escape(ticket.announcement_note)}")
          end
        end
      end
      event.recipients.each do |id|
        member = Member.where(id: id).first
        next unless member && !member.direct_notifications_suppressed? && FixTicketPolicy.new(member, ticket).read?
        slack = SlackUser.where(member_id: id).first
        next unless slack
        publish(event, "dm-#{id}", Service::SlackConnector.safe_channel(slack.slack_id), text)
      end
      event.set(completed_at: Time.current, delivery_error: nil)
    rescue StandardError => error
      event.set(delivery_error: error.class.name)
      raise
    end
    def root!(ticket, event, channel, team)
      if ticket.slack_ticket_ts.present? && ticket.slack_ticket_team_id == team
        begin
          # Resolve configured names to IDs before comparing persisted destinations.
          configured = channel.start_with?('C', 'G', 'D') ? channel : Service::SlackChannelCache.fetch(channel)&.dig(:id)
          if configured == ticket.slack_ticket_channel_id
            client.chat_getPermalink(channel: ticket.slack_ticket_channel_id, message_ts: ticket.slack_ticket_ts)
            return ticket.slack_ticket_ts
          end
        rescue Slack::Web::Api::Errors::SlackError => error
          raise unless error.message.include?('message_not_found')
        end
      end
      key = "root-#{channel}-#{ticket.slack_ticket_ts || 'initial'}"
      response = post(event, key, channel, summary(ticket))
      # Collection update intentionally does not touch the user-visible updated_at.
      ticket.set(slack_ticket_ts: response.fetch('ts'), slack_ticket_channel_id: response.fetch('channel'), slack_ticket_team_id: team)
      ticket.slack_ticket_ts
    end
    def publish(event, key, channel, text, thread_ts: nil, broadcast: false, namespace: nil)
      text.chars.each_slice(2900).map(&:join).each_with_index do |part, index|
        receipt_key = "#{key}-#{index}"
        if key == 'central'
          # Preserve pre-upgrade receipts/uncertain sends only in their original
          # thread. A replacement root must receive every chunk with fresh IDs.
          legacy = event.delivery_attempts[receipt_key]
          unless legacy && legacy['channel'] == channel && legacy['thread_ts'] == thread_ts
            destination = Digest::SHA256.hexdigest([namespace, channel, thread_ts].join('/'))
            receipt_key = "central-#{destination}-#{index}"
          end
        end
        post(event, receipt_key, channel, part, thread_ts: thread_ts, broadcast: broadcast && index.zero?)
      end
    end
    def reconcile(attempt, uuid)
      cursor = nil
      loop do
        args = { channel: attempt.fetch('channel'), oldest: attempt.fetch('oldest'), limit: 100, cursor: cursor }
        response = if attempt['thread_ts']
          client.conversations_replies(**args.merge(ts: attempt['thread_ts']))
        else
          client.conversations_history(**args)
        end
        found = Array(response['messages']).find { |message| message['client_msg_id'] == uuid }
        return { 'ts' => found['ts'], 'channel' => attempt['channel'] } if found
        cursor = response.dig('response_metadata', 'next_cursor').presence
        break unless cursor
      end
      nil
    end
    def post(event, key, channel, text, thread_ts: nil, broadcast: false)
      return event.delivered[key] if event.delivered[key].is_a?(Hash)
      # Stable client_msg_id makes retrying a timed-out request refer to the same
      # logical Slack message rather than inventing a fresh delivery identity.
      digest = Digest::SHA256.hexdigest("#{event.id}/#{key}")
      uuid = [digest[0,8], digest[8,4], digest[12,4], digest[16,4], digest[20,12]].join('-')
      # chat_postMessage already accepts a raw user id as `channel` and
      # resolves/opens the DM internally (same as Service::SlackConnector's
      # existing send_slack_message) -- pre-resolving it ourselves via
      # conversations_open needs the im:write scope, which this bot token
      # doesn't have and has never needed elsewhere in the app.
      attempt = event.delivery_attempts[key]
      if attempt
        receipt = reconcile(attempt, uuid)
        if receipt
          event.set(delivered: event.delivered.merge(key => receipt))
          return receipt
        end
      end
      # Persist intent before the network call. A crash/timeout is reconciled
      # against Slack history before any subsequent send is attempted.
      attempt = { 'channel' => channel, 'thread_ts' => thread_ts, 'oldest' => (Time.current.to_f - 5).to_s }
      event.set(delivery_attempts: event.delivery_attempts.merge(key => attempt))
      response = client.chat_postMessage(channel: channel, text: text, thread_ts: thread_ts,
        reply_broadcast: broadcast, client_msg_id: uuid, parse: 'none', link_names: false, unfurl_links: false, unfurl_media: false)
      Thread.current[:fix_delivery_lease]&.call
      receipt = { 'ts' => response['ts'], 'channel' => response['channel'] }
      event.set(delivered: event.delivered.merge(key => receipt))
      receipt
    end
  end
end
