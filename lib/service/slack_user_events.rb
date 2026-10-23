module Service
  module SlackUserEvents
    EVENT_TYPES = %w[team_join user_change].freeze

    def self.process(event = nil, event_id: nil, **event_keywords)
      event ||= event_keywords
      event = event.to_h.stringify_keys
      return unless EVENT_TYPES.include?(event['type'])

      user = event['user'].to_h.stringify_keys
      event_ts = slack_event_timestamp(event)
      if user['deleted'] == true
        invalidate_deleted_user(user, event_id, event_ts)
        return
      end
      return if non_member?(user)

      persist(user, event_id: event_id, event_ts: event_ts)
      welcome_if_needed(user) if event['type'] == 'team_join'
    rescue => error
      Rails.logger.error("[SlackUserEvent] #{error.class}: #{error.message}")
      Honeybadger.notify(error, context: {
        slack_event_id: event_id.to_s,
        slack_event_type: event['type'].to_s,
        slack_user_id: event.dig('user', 'id').to_s
      }) if defined?(Honeybadger)
      raise
    end

    def self.non_member?(user)
      user['is_bot'] == true || user['is_app_user'] == true
    end

    def self.invalidate_deleted_user(user, event_id, event_ts)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      attributes = {
        invalidated_at: Time.current,
        invalidation_reason: "slack_user_deleted; event_id=#{event_id}"
      }
      attributes[:last_slack_event_ts] = event_ts if event_ts

      record = SlackUser.unscoped.where(slack_id: slack_id).first
      unless record
        # Persist a tombstone even without a prior identity, so a later,
        # out-of-order event for this slack_id has something to check
        # ordering against instead of creating a fresh active identity for
        # an account Slack already reported deleted.
        SlackUser.create!(attributes.merge(slack_id: slack_id))
        return
      end

      criteria = { _id: record.id }
      criteria['$or'] = event_order_filters(event_ts, inclusive: true) if event_ts
      SlackUser.collection.find(criteria).update_one('$set' => attributes)
    end

    def self.persist(user, event_id:, event_ts:)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      profile = user['profile'].to_h.stringify_keys
      email = profile['email'].to_s.strip.downcase.presence
      member = Member.find_by(email: email) if email
      by_slack = SlackUser.unscoped.where(slack_id: slack_id).first
      return false if quarantined_identity?(by_slack)

      linked_member = by_slack&.member
      email_mismatch = linked_member && email && normalize_email(linked_member.email) != email
      if email_mismatch
        member = linked_member
      end

      attributes = {
        slack_email: email && SlackUser.scrub_user_input(email),
        name: SlackUser.scrub_user_input(user['name'].to_s.strip),
        real_name: SlackUser.scrub_user_input((user['real_name'].presence || profile['real_name']).to_s.strip),
        member_id: member&.id
      }.compact

      by_member = SlackUser.find_by(member_id: member.id) if member
      record = email_mismatch ? by_slack : (by_member || by_slack)
      return false unless event_can_apply?(record, event_ts)

      merging_identity = by_slack && by_member && by_slack.id != by_member.id
      # The ordering check above only covers `record` (by_member here), but
      # destroying by_slack discards its own state (e.g. a newer deletion
      # tombstone). Require the event to also be current for by_slack itself
      # before merging its identity away.
      return false if merging_identity && !event_can_apply?(by_slack, event_ts)

      by_slack.destroy! if merging_identity

      if record
        # SlackUser marks imported identity fields readonly, so event-driven
        # synchronization deliberately writes through the collection.
        # A deletion at the same timestamp wins, and events without an
        # ordering timestamp can never revive an invalidated identity.
        criteria = { _id: record.id }
        criteria['$or'] = event_order_filters(event_ts, inclusive: false) if event_ts
        updated_attributes = attributes.merge(slack_id: slack_id)
        updated_attributes[:last_slack_event_ts] = event_ts if event_ts
        update = { '$set' => updated_attributes }
        update['$unset'] = { invalidated_at: '', invalidation_reason: '' } if event_ts
        result = SlackUser.collection.find(criteria).update_one(update)
        applied = result.matched_count == 1
        report_email_mismatch(linked_member, email, slack_id, event_id) if applied && email_mismatch
        applied
      else
        attributes[:last_slack_event_ts] = event_ts if event_ts
        SlackUser.create!(attributes.merge(slack_id: slack_id))
        true
      end
    end

    def self.event_can_apply?(record, event_ts)
      return true unless record
      return false if record.invalidated_at && event_ts.nil?
      return true unless event_ts && record.last_slack_event_ts

      event_ts > record.last_slack_event_ts
    end

    def self.quarantined_identity?(record)
      record&.invalidated_at.present? &&
        record.invalidation_reason.to_s.start_with?('member_email_changed')
    end

    def self.slack_event_timestamp(event)
      Float(event['event_ts'])
    rescue ArgumentError, TypeError
      nil
    end

    def self.event_order_filters(event_ts, inclusive:)
      comparison = inclusive ? '$lte' : '$lt'
      [
        { last_slack_event_ts: nil },
        { last_slack_event_ts: { comparison => event_ts } }
      ]
    end

    def self.report_email_mismatch(member, slack_email, slack_id, event_id)
      Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'slack_email_mismatch',
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        field_changes: {
          'slack_email' => [normalize_email(member.email), slack_email]
        },
        message_details: "Slack user #{slack_id} changed their Slack email, but the Member record was not changed. " \
          "An admin must reconcile the Member email and Slack email. Slack event ID: #{event_id}.",
        slack_channel: Service::SlackConnector.logs_channel
      )
    end

    def self.normalize_email(email)
      email.to_s.strip.downcase
    end

    def self.welcome_if_needed(user)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      record = SlackUser.find_by(slack_id: slack_id)
      return unless record
      return if record.welcomed_at.present?

      # Welcoming is tracked independently of persist's event-ordering check:
      # a failed Slack call must be retryable even when the identity update
      # itself was a no-op (e.g. a retry of an already-applied event).
      welcome(user)
      SlackUser.collection.find(_id: record.id).update_one('$set' => { welcomed_at: Time.current })
    end

    def self.welcome(user)
      name = user['real_name'].presence || user.dig('profile', 'real_name').presence || user['name']
      message = "Welcome to the makerspace #{name}! (<@#{user['id']}>)\n" \
        'This is a good channel to introduce yourself and ask questions.'
      channel = Service::SlackConnector.new_members_channel
      Service::SlackConnector.send_slack_message(message, channel)
    end

    private_class_method :non_member?, :invalidate_deleted_user, :persist, :event_can_apply?,
      :quarantined_identity?, :slack_event_timestamp, :event_order_filters,
      :report_email_mismatch, :normalize_email, :welcome_if_needed, :welcome
  end
end
