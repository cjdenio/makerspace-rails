module Service
  module AuditLogger
    # ── Sensitive fields scrubbed from all snapshots ───────────────────────
    SCRUBBED_FIELDS = %w[
      encrypted_password
      reset_password_token
      otp_secret_encrypted
      session_token
      remember_created_at
    ].freeze

    # ── Required fields ────────────────────────────────────────────────────
    REQUIRED_FIELDS = %i[log_type event_type resource_type resource_id].freeze

    # ── Known field formatters for human-readable change summaries ─────────
    # Fields whose raw values need translation before display in Slack.
    # Keys are field name strings; values are lambdas that take the raw value.
    FIELD_FORMATTERS = {
      'expirationTime' => ->(v) {
        return 'none' if v.nil?
        Time.at(v.to_i / 1000).strftime('%m/%d/%Y') rescue v.to_s
      },
      'expiration' => ->(v) {
        return 'none' if v.nil?
        Time.at(v.to_i / 1000).strftime('%m/%d/%Y') rescue v.to_s
      }
    }.freeze

    # ── Public interface ───────────────────────────────────────────────────
    #
    # Params (all keyword arguments):
    #
    #   log_type:        (required) "member" | "portal"
    #   event_type:      (required) e.g. "member_updated", "membership_revoked"
    #   resource_type:   (required) Mongoid model class name, e.g. "Member"
    #   resource_id:     (required) BSON::ObjectId of the record changed
    #
    #   actor:           (optional) Member instance — who made the change.
    #                    Falls back to Current.actor if not passed.
    #                    Nil for system-initiated events.
    #   subject:         (optional) Member instance — who was affected.
    #                    Nil for portal logs.
    #
    #   field_changes:   (optional) Hash of changed fields: { "field" => [before, after] }
    #                    Pass model.previous_changes after a save, or build manually.
    #                    Named field_changes to avoid collision with Mongoid::Changeable#changes.
    #   before_snapshot: (optional) Hash — full document before the change.
    #   after_snapshot:  (optional) Hash — full document after the change.
    #
    #   slack_channel:   (optional) Channel to post to. Omit to skip Slack entirely.
    #
    # Returns the persisted AuditLog document, or nil if the write failed
    # (Honeybadger is notified on failure; the caller's request is not interrupted).
    #
    def self.log(
      log_type:,
      event_type:,
      resource_type:,
      resource_id:,
      actor: nil,
      subject: nil,
      field_changes: nil,
      before_snapshot: nil,
      after_snapshot: nil,
      slack_channel: nil
    )
      validate_required!(log_type: log_type, event_type: event_type,
                         resource_type: resource_type, resource_id: resource_id)

      # Resolve actor from argument or Current thread-local
      resolved_actor = actor || Current.actor

      actor_id   = resolved_actor&.id
      actor_name = resolved_actor&.fullname

      subject_id   = subject&.id
      subject_name = subject&.fullname

      # Scrub snapshots and field_changes before storage
      clean_before = scrub(before_snapshot)
      clean_after  = scrub(after_snapshot)
      clean_field_changes = scrub_field_changes(field_changes)

      # Always generate the Slack message — stored even when not posted
      message = generate_message(
        event_type:    event_type,
        actor_name:    actor_name,
        subject_name:  subject_name,
        resource_type: resource_type,
        field_changes: clean_field_changes
      )

      # Attempt Slack post if a channel was provided
      slack_posted = attempt_slack(message, slack_channel)

      # Build and persist the log entry
      entry = AuditLog.new(
        log_type:        log_type,
        event_type:      event_type,
        actor_id:        actor_id,
        actor_name:      actor_name,
        subject_id:      subject_id,
        subject_name:    subject_name,
        resource_type:   resource_type,
        resource_id:     to_object_id(resource_id),
        field_changes:   clean_field_changes,
        before_snapshot: clean_before,
        after_snapshot:  clean_after,
        slack_channel:   slack_channel,
        slack_message:   message,
        slack_posted:    slack_posted,
        ip_address:      Current.ip_address
      )

      begin
        entry.save!
        Rails.logger.info("[AuditLogger] #{event_type} on #{resource_type}:#{resource_id} by #{actor_id}")
        entry
      rescue => e
        notify_honeybadger(e, context: {
          log_type:      log_type,
          event_type:    event_type,
          resource_type: resource_type,
          resource_id:   resource_id.to_s,
          actor_id:      actor_id.to_s
        })
        nil
      end
    end

    # ── Private ────────────────────────────────────────────────────────────
    private

    # Raises immediately (programming error) if any required keyword is blank.
    # Notifies Honeybadger before raising so it shows up in the error tracker
    # even if the exception is somehow swallowed further up the stack.
    def self.validate_required!(**fields)
      REQUIRED_FIELDS.each do |key|
        next if fields[key].present?

        err = ArgumentError.new(
          "[AuditLogger] Required field missing: #{key}. " \
          "Called with: #{fields.inspect}"
        )
        notify_honeybadger(err, context: fields.transform_values(&:to_s))
        raise err
      end
    end

    # Removes sensitive fields from a snapshot hash.
    # Returns nil if the input is nil (creation events have no before snapshot).
    def self.scrub(snapshot)
      return nil if snapshot.nil?
      snapshot.reject { |k, _| SCRUBBED_FIELDS.include?(k.to_s) }
    end

    # Removes sensitive fields from a field_changes hash. Shape differs from
    # snapshot()'s input — { "field" => [before, after] } rather than a flat
    # { "field" => value } — so this needs its own filter rather than reusing
    # scrub(). This is a defense-in-depth safeguard: callers should already
    # avoid feeding sensitive-field diffs into field_changes (e.g. by
    # capturing previous_changes before any save that rotates a credential
    # like session_token), but this ensures a leak can't occur here even if
    # a caller gets that ordering wrong in the future.
    def self.scrub_field_changes(field_changes)
      return nil if field_changes.nil?
      field_changes.reject { |k, _| SCRUBBED_FIELDS.include?(k.to_s) }
    end

    # Generates a human-readable Slack message from structured data.
    # Always produced; only posted when slack_channel is present.
    def self.generate_message(event_type:, actor_name:, subject_name:, resource_type:, field_changes:)
      parts = []

      # Lead with event label
      parts << "*#{event_type.to_s.humanize}*"

      # Actor
      parts << "by #{actor_name}" if actor_name.present?

      # Subject and resource
      if subject_name.present?
        parts << "on #{subject_name}'s #{resource_type}"
      else
        parts << "on #{resource_type}"
      end

      # Change summary
      if field_changes.present?
        diff = format_changes(field_changes)
        parts << "— #{diff}" if diff.present?
      end

      parts.join(' ')
    end

    # Formats the field_changes hash into a readable string.
    # { "status" => ["activeMember", "revoked"] } → "status: activeMember → revoked"
    def self.format_changes(field_changes)
      field_changes.map do |field, (before, after)|
        formatter = FIELD_FORMATTERS[field.to_s]
        if formatter
          "#{field}: #{formatter.call(before)} → #{formatter.call(after)}"
        else
          "#{field}: #{before} → #{after}"
        end
      end.join(', ')
    end

    # Attempts a Slack post if a channel is provided.
    # Returns true/false if attempted, nil if skipped.
    # Notifies Honeybadger on failure but does not raise.
    def self.attempt_slack(message, channel)
      return nil if channel.blank?

      begin
        ::Service::SlackConnector.send_slack_message(message, channel)
        true
      rescue => e
        notify_honeybadger(e, context: { slack_channel: channel, slack_message: message })
        false
      end
    end

    # Coerces resource_id to BSON::ObjectId safely.
    def self.to_object_id(id)
      return id if id.is_a?(BSON::ObjectId)
      BSON::ObjectId.from_string(id.to_s)
    rescue
      nil
    end

    # Notifies Honeybadger if available; logs to Rails.logger as fallback.
    def self.notify_honeybadger(error, context: {})
      if defined?(Honeybadger)
        Honeybadger.notify(error, context: context)
      else
        Rails.logger.error("[AuditLogger] #{error.class}: #{error.message} | context: #{context.inspect}")
      end
    end
  end
end
