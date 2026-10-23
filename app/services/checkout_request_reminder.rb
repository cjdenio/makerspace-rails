# "Still waiting" reminders for open checkout requests. A request that has been
# open for 5 days gets a post in the configured Resource Managers channel
# (`slack_channel_rm`), and another every 5 days after that, up to 3 reminders.
# The third says it is the last reminder. If no checkout is recorded 5 days after
# the third reminder the system declines the request (see `time_out_due!`).
# When the request is approved, declined, timed out or cancelled, each reminder
# that was posted is edited to say so, so the channel is not left with stale
# reminders.
#
# Each reminder has a receipt on the request (`reminders`, keyed by reminder
# number). A short lease prevents concurrent workers posting the same reminder
# twice; failed or expired attempts are retried by the next scan. A reminder that
# was posted but whose resolution edit failed stays `reminder_open` and is
# retried by the daily job.
module CheckoutRequestReminder
  INTERVAL_DAYS = 5
  # Reminders actually posted, not elapsed intervals, so a request that is already
  # old when this ships still gets all of them before it is declined.
  MAX_REMINDERS = 3
  LEASE = 5.minutes

  class << self
    # Calendar days in the application time zone, so the reminder and the
    # approver digest agree on how old a request is.
    def due_number(request, now)
      return 0 unless request.request_date

      ((now.in_time_zone.to_date - request.request_date.in_time_zone.to_date).to_i / INTERVAL_DAYS).floor
    end

    def remind!(request, now: Time.current)
      request.reload
      return unless request.open? && request.target
      return if sent_receipts(request).size >= MAX_REMINDERS

      number = due_number(request, now)
      return if number < 1

      key = number.to_s
      token = claim(request, key, now)
      return unless token

      begin
        request.reload
        unless request.open?
          release(request, key, token, 'obsolete', now)
          return
        end
        channel = Service::SlackConnector.resource_managers_channel
        declines_on = (now.in_time_zone.to_date + INTERVAL_DAYS) if sent_receipts(request).size + 1 >= MAX_REMINDERS
        response = Service::SlackConnector.send_slack_message(waiting_message(request, declines_on: declines_on), channel)
        finish(request, key, token, 'sent', now,
               'channel' => (response.channel if response.respond_to?(:channel)) || channel,
               'ts' => (response.ts if response.respond_to?(:ts)))
      rescue => error
        finish(request, key, token, 'failed', now, 'error_class' => error.class.name)
        raise
      end
    end

    # Decline a request once all reminders have been posted and the last one has had
    # its full interval with no checkout recorded. Returns true when it declined.
    def time_out_due!(request, now: Time.current)
      request.reload
      return false unless request.open?

      sent = sent_receipts(request)
      return false if sent.size < MAX_REMINDERS

      last_sent = sent.map { |receipt| receipt['sent_at'] }.compact.max
      return false unless last_sent && last_sent.in_time_zone.to_date <= now.in_time_zone.to_date - INTERVAL_DAYS

      CheckoutRequestDecision.time_out!(request: request, now: now)
    end

    def sent_receipts(request)
      request.reminders.values.select { |receipt| receipt['status'] == 'sent' }
    end

    # Edit every posted reminder for a request that is no longer open.
    def finalize!(request, now: Time.current)
      request.reload
      return if request.open? || !request.reminder_open

      request.reminders.each do |key, receipt|
        next unless receipt['status'] == 'sent' && !receipt['finalized'] && receipt['ts'].present?

        Service::SlackConnector.update_slack_message(receipt['channel'], receipt['ts'],
                                                     resolved_message(request), resolved_channel: true)
        ToolCheckoutRequest.collection.find('_id' => request.id)
                           .update_one('$set' => { "reminders.#{key}.finalized" => true,
                                                   "reminders.#{key}.finalized_at" => now })
      end
      request.reload
      unresolved = request.reminders.any? do |_, receipt|
        receipt['status'] == 'sent' && receipt['ts'].present? && !receipt['finalized']
      end
      request.set(reminder_open: false) unless unresolved
    end

    def waiting_message(request, declines_on: nil)
      text = "*#{CheckoutDisplay.escape(request.member.fullname)}* requested checkout on " \
             "*#{CheckoutDisplay.escape(request.target.name)}* (#{CheckoutDisplay.escape(request.target.shop&.name)}) " \
             "on #{request.request_date.to_date.iso8601} and is still waiting. "
      if declines_on
        text + "This is the last reminder: if no checkout is recorded it will be automatically declined on " \
               "#{declines_on.iso8601}. If this was already done in person, please record the checkout."
      else
        text + "If this was already done in person, please record the checkout so this stops."
      end
    end

    def resolved_message(request)
      outcome = case request.status
                when 'declined' then request.timed_out? ? 'timed out and was automatically declined' : 'declined'
                when 'deleted' then 'cancelled by the requester'
                else 'approved'
                end
      "Checkout request from *#{CheckoutDisplay.escape(request.member.fullname)}* for " \
        "*#{CheckoutDisplay.escape(request.target&.name)}* (#{request.request_date.to_date.iso8601}) " \
        "is no longer waiting: #{outcome}."
    end

    private

    def claim(request, key, now)
      token = SecureRandom.hex(8)
      path = "reminders.#{key}"
      claimed = ToolCheckoutRequest.collection.find(
        '_id' => request.id, 'status' => 'open',
        '$and' => [
          { "#{path}.status" => { '$ne' => 'sent' } },
          { '$or' => [{ "#{path}.lease_until" => nil }, { "#{path}.lease_until" => { '$lt' => now } }] }
        ]
      ).find_one_and_update('$set' => { path => { 'status' => 'sending', 'token' => token,
                                                   'lease_until' => now + LEASE, 'started_at' => now,
                                                   'finalized' => false },
                                        'reminder_open' => true })
      claimed ? token : nil
    end

    def finish(request, key, token, status, now, extra = {})
      path = "reminders.#{key}"
      receipt = { 'status' => status, 'token' => token, 'finished_at' => now, 'finalized' => false }
      receipt['sent_at'] = now if status == 'sent'
      receipt.merge!(extra.compact)
      ToolCheckoutRequest.collection.find('_id' => request.id, "#{path}.token" => token)
                         .find_one_and_update('$set' => { path => receipt })
    end

    def release(request, key, token, status, now)
      finish(request, key, token, status, now)
    end
  end
end
