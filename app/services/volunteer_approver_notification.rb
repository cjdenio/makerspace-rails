require 'securerandom'

# A task submission has one review per claimant; each scheduled event date has
# one attendance review. Persist each manager's receipt separately so retries
# do not notify managers whose DM has already succeeded for that schedule.
class VolunteerApproverNotification
  DELIVERY_LEASE = 5.minutes

  class << self
    def notify!(record, now: Time.current)
      record.reload
      preserve_event_receipts!(record, event_date: record.event_date) if record.is_a?(VolunteerEvent)
      return unless ready?(record, now) && record.shop_id.present?

      Member.where(role: 'resource_manager', resource_manager_shop_ids: record.shop_id.to_s).each do |manager|
        next unless manager.manages_shop?(record.shop_id)
        next if manager.direct_notifications_suppressed?
        next if record.is_a?(VolunteerTask) && manager.id == record.claimed_by_id

        slack_user = SlackUser.find_by(member_id: manager.id)
        next unless slack_user&.slack_id.present?

        deliver!(record, manager, now)
      rescue => error
        Service::ErrorReporter.notify(error)
      end
    rescue => error
      Service::ErrorReporter.notify(error)
    end

    def ready?(record, now)
      if record.is_a?(VolunteerEvent)
        record.status == 'open' && record.event_date.present? && record.event_date < now.in_time_zone.to_date
      else
        record.status == 'pending' && record.completed_at.present?
      end
    end

    def review_url(record)
      parameter = record.is_a?(VolunteerEvent) ? 'event' : 'task'
      "#{ShortUrl.base_url}/volunteer?#{parameter}=#{record.id}"
    end

    # Bind pre-versioning receipts to their existing schedule before a normal
    # reschedule changes event_date. Also adopt them on the first daily scan so
    # deploying date-versioned receipts does not resend an unchanged event DM.
    def preserve_event_receipts!(record, event_date:)
      return if record.approver_notifications.fetch('event', {}).blank?

      destination = "approver_notifications.#{event_submission_key(event_date)}"
      saved = record.class.collection.find(
        '_id' => record.id,
        'event_date' => native_date(event_date),
        'approver_notifications.event' => { '$exists' => true },
        destination => { '$exists' => false }
      ).find_one_and_update(
        { '$rename' => { 'approver_notifications.event' => destination } }, return_document: :after
      )
      return if saved
      # A concurrent adopter may already have moved the legacy bucket. Any
      # still-present legacy receipts must be bound before a date update saves.
      return unless record.class.collection.find(
        '_id' => record.id, 'approver_notifications.event' => { '$exists' => true }
      ).first

      raise 'Legacy event approver receipts could not be bound to the existing schedule'
    end

    private

    def submission_key(record)
      record.is_a?(VolunteerEvent) ? event_submission_key(record.event_date) :
        "submission_#{(record.completed_at.to_f * 1000).round}"
    end

    def event_submission_key(date)
      date.present? ? "event_#{date.strftime('%Y%m%d')}" : 'event_undated'
    end

    def terminal_submission?(record)
      record.is_a?(VolunteerEvent) ? record.status == 'closed' : %w[completed cancelled denied].include?(record.status)
    end

    def deliver!(record, manager, now)
      return unless ready?(record, now)

      claim_key = submission_key(record)
      manager_id = manager.id
      path = "approver_notifications.#{claim_key}.#{manager_id}"
      token = SecureRandom.uuid
      selector = { '_id' => record.id, 'status' => record.status }
      selector['completed_at'] = native_time(record.completed_at) if record.is_a?(VolunteerTask)
      selector['event_date'] = native_date(record.event_date) if record.is_a?(VolunteerEvent)
      selector['$or'] = [
        { path => { '$exists' => false } },
        { "#{path}.state" => 'failed' },
        { "#{path}.state" => 'sending', "#{path}.attempted_at" => { '$lt' => native_time(now - DELIVERY_LEASE) } }
      ]

      acquired = record.class.collection.find(selector).find_one_and_update(
        { '$set' => { path => { 'state' => 'sending', 'token' => token, 'attempted_at' => native_time(now) } } },
        return_document: :after
      )
      return unless acquired

      posted = false
      begin
        # The record or manager's eligibility can change while the lease is acquired.
        record.reload
        begin
          manager.reload
        rescue Mongoid::Errors::DocumentNotFound
          finish!(record, path, token, { 'state' => 'obsolete' })
          return
        end
        # With raise_not_found_error disabled, a missing member reloads with a
        # new default ID rather than raising. Its original receipt is obsolete.
        if manager.id != manager_id || terminal_submission?(record) ||
            (record.is_a?(VolunteerTask) && submission_key(record) != claim_key)
          finish!(record, path, token, { 'state' => 'obsolete' })
          return
        end

        # Readiness, authority and notification eligibility can be restored
        # while the same submission still awaits review.
        unless submission_key(record) == claim_key && ready?(record, now) &&
            record.shop_id.present? && manager.manages_shop?(record.shop_id) &&
            !manager.direct_notifications_suppressed? &&
            !(record.is_a?(VolunteerTask) && manager_id == record.claimed_by_id)
          finish!(record, path, token, { 'state' => 'failed' })
          return
        end

        # Provisioning can invalidate or reassign the link after enumeration.
        # Keep the delivery retryable until this manager has a current identity.
        slack_user = SlackUser.find_by(member_id: manager_id)
        unless slack_user&.slack_id.present? && slack_user.member_id == manager_id && slack_user.invalidated_at.blank?
          finish!(record, path, token, { 'state' => 'failed' })
          return
        end

        response = Service::SlackConnector.send_slack_message(message(record), slack_user.slack_id)
        ts = response && (response['ts'] || response[:ts])
        channel = response && (response['channel'] || response[:channel])
        raise 'Slack did not return an approver DM receipt' if ts.blank? || channel.blank?
        posted = true

        finish!(record, path, token, {
          'state' => 'sent', 'ts' => ts, 'channel' => channel, 'sent_at' => native_time(now),
          'destination_mode' => Service::SlackConnector.message_destination_mode
        })
      rescue => error
        # An accepted post whose receipt write failed is uncertain: retain the
        # sending lease and report it, rather than immediately reposting it.
        finish!(record, path, token, { 'state' => 'failed' }) unless posted
        raise error
      end
    end

    def finish!(record, path, token, attributes)
      saved = record.class.collection.find('_id' => record.id, "#{path}.token" => token).find_one_and_update(
        { '$set' => attributes.transform_keys { |name| "#{path}.#{name}" } }, return_document: :after
      )
      raise 'Volunteer approver DM receipt could not be saved; delivery may have succeeded' unless saved
    end

    def message(record)
      subject = if record.is_a?(VolunteerEvent)
        "Event *#{escape(record.title)}* (#{record.display_number}) is ready for attendance review " \
          "with #{record.attendee_count} checked-in attendee#{'s' unless record.attendee_count == 1}. " \
          'Review attendance and close the event to issue credits.'
      else
        claimant = record.claimed_by&.fullname || 'Unknown member'
        "*#{escape(claimant)}* submitted completion of *#{escape(record.title)}* (#{record.display_number}). " \
          'Please review this volunteer credit claim when you can.'
      end
      "#{subject}\n<#{review_url(record)}|Review #{record.is_a?(VolunteerEvent) ? 'event attendance' : 'claim'}>"
    end

    def escape(value)
      value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def native_time(value)
      Time.at(value.to_r).utc
    end

    def native_date(value)
      Time.utc(value.year, value.month, value.day) if value
    end
  end
end
