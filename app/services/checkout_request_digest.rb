# A Slack DM roll-up for each approver listing every open checkout request they
# can act on (requests they could not approve, such as one from an expired member,
# are left out), oldest requester first: who asked, for which tool, and how many days
# it has waited. To keep the volume low, a recipient is messaged at most once a
# day, and only when
#
#   * there is a request they can act on that is new since their last digest, or
#   * some open request they can act on is exactly 5, 10, 15, ... days old.
#
# The digest always lists all of their open requests, not just the new or old
# ones. Days are calendar days in the application time zone.
#
# Recipients are the resource managers for the request's shop and the approvers
# assigned to the tool, its shop, or the requested group. Admin and board members
# are not included unless they also hold one of those roles, and the requester is
# never a recipient of their own request. Someone with no open requests gets no
# message. Recipients without a linked Slack account, or whose direct
# notifications are suppressed (`revoked` or `suspended`), are skipped.
#
# When a new digest is sent, the recipient's previous digest is edited into a short
# "replaced" stub (chat.update), so their history keeps one live list instead of a
# pile of out-of-date ones. The new message is always a fresh post so that it
# notifies; Slack does not alert on edits. A failed edit never blocks or repeats
# the new digest.
#
# A per-recipient, per-day Redis key stops a rerun of the job from sending the
# same digest twice; a failed send releases the key so the next run retries it.
module CheckoutRequestDigest
  MAX_REQUESTERS = 30
  MILESTONE_DAYS = 5
  KEY_TTL = 36.hours
  LAST_TTL = 90.days
  MESSAGE_TTL = 30.days
  # An approver who did the checkout in person but never recorded it keeps seeing the request.
  DONE_IN_PERSON = "Already did one in person? Record it (Approve in Slack, or Check Out Member in the portal) so it stops showing up.".freeze
  REPLACED_TEXT = 'Replaced by a newer digest below.'.freeze

  class << self
    def deliver_all!(now: Time.current)
      recipients_with_requests.each do |member, requests|
        next unless due?(member, requests, now)

        deliver(member, requests, now: now)
      rescue => error
        Service::ErrorReporter.notify(error, context: { phase: 'checkout request digest',
                                                        member_id: member.id.to_s })
      end
    end

    # { Member => [ToolCheckoutRequest, ...] } for every eligible recipient.
    def recipients_with_requests
      result = Hash.new { |hash, member| hash[member] = [] }
      ToolCheckoutRequest.where(status: 'open').each do |request|
        next unless request.target && request.member && actionable?(request)

        recipients(request).each { |member| result[member] << request }
      end
      result
    end

    # Only requests an approver could actually act on: the same test the Slack
    # "View open requests" list applies. A request from an expired, inactive,
    # revoked or suspended member, one with unmet prerequisites, or one for a
    # disabled tool or group is left out, as is a group whose tools are all held.
    def actionable?(request)
      if request.tool_group_id
        ToolGroupCheckout.validate_review!(ToolGroupCheckout.review(member: request.member, group: request.target))
        true
      else
        ToolCheckoutRequestEligibility.new(member: request.member, tool: request.target,
                                           open_request_tool_ids: []).error.nil?
      end
    rescue Error::CustomError
      false
    end

    def recipients(request)
      target = request.target
      return [] unless target&.shop_id

      shop_id = target.shop_id
      managers = Member.where(role: 'resource_manager',
                              :resource_manager_shop_ids.in => [shop_id, shop_id.to_s]).to_a
      (managers + assigned_approvers(request, target, shop_id)).uniq(&:id)
                                                               .reject { |member| member.id == request.member_id }
                                                               .select { |member| eligible?(member) }
    end

    def message(requests, now: Time.current)
      groups = requests.group_by(&:member_id).values.sort_by { |rows| rows.map(&:request_date).min }
      lines = ["Open checkout requests (#{requests.size})", '']
      groups.first(MAX_REQUESTERS).each do |rows|
        lines << CheckoutDisplay.escape(rows.first.member.fullname)
        rows.sort_by(&:request_date).each do |request|
          lines << "  • #{CheckoutDisplay.escape(request.target.name)} " \
                   "(#{CheckoutDisplay.escape(request.target.shop&.name)}) – #{age(request, now)}"
        end
      end
      lines << "and #{groups.size - MAX_REQUESTERS} more members, see the Member Portal." if groups.size > MAX_REQUESTERS
      lines << ''
      lines << 'use /checkout → View open requests, or use the Member Portal'
      lines << DONE_IN_PERSON
      lines.join("\n")
    end

    # A digest is due for new requests since the last one, or on a 5-day milestone.
    def due?(member, requests, now)
      since = last_digest_at(member, now)
      requests.any? { |request| request.request_date > since } ||
        requests.any? { |request| milestone?(age_days(request, now)) }
    end

    def milestone?(days)
      days >= MILESTONE_DAYS && (days % MILESTONE_DAYS).zero?
    end

    def age_days(request, now)
      (now.in_time_zone.to_date - request.request_date.in_time_zone.to_date).to_i
    end

    def age(request, now)
      days = age_days(request, now)
      return 'less than a day old' if days < 1

      "#{days} #{'day'.pluralize(days)} old"
    end

    private

    def assigned_approvers(request, target, shop_id)
      match = [{ :shop_ids.in => [shop_id, shop_id.to_s] }]
      if request.tool_group_id
        match << { :tool_group_ids.in => [request.tool_group_id, request.tool_group_id.to_s] }
      else
        match << { :tool_ids.in => [request.tool_id, request.tool_id.to_s] }
      end
      CheckoutApprover.any_of(*match).to_a.select do |approver|
        request.tool_group_id ? approver.can_approve_group?(target) : approver.can_approve_tool?(target)
      end.map(&:member).compact.select(&:valid_for_checkout_request?)
    end

    def eligible?(member)
      !member.direct_notifications_suppressed? && slack_id_for(member).present?
    end

    def message_key(member)
      "checkout_request_digest_message:#{member.id}"
    end

    # Edit the previous digest into a stub and remember the one just sent. Best
    # effort: nothing here may raise, since the new digest has already been sent.
    def replace_previous(member, response, slack_id)
      previous = REDIS.get(message_key(member))
      if previous.present?
        ref = JSON.parse(previous)
        Service::SlackConnector.update_slack_message(ref['channel'], ref['ts'], REPLACED_TEXT, resolved_channel: true)
      end
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: 'checkout request digest replace previous',
                                                      member_id: member.id.to_s })
    ensure
      remember(member, response, slack_id)
    end

    def remember(member, response, slack_id)
      return unless response.respond_to?(:ts) && response.ts.present?

      channel = (response.channel if response.respond_to?(:channel)) || slack_id
      REDIS.set(message_key(member), { channel: channel, ts: response.ts }.to_json, ex: MESSAGE_TTL.to_i)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: 'checkout request digest remember message',
                                                      member_id: member.id.to_s })
    end

    def last_key(member)
      "checkout_request_digest_last:#{member.id}"
    end

    # When this member was last sent a digest; a day ago if they never were.
    def last_digest_at(member, now)
      value = REDIS.get(last_key(member))
      value.present? ? Time.zone.at(value.to_i) : now - 1.day
    end

    def slack_id_for(member)
      SlackUser.find_by(member_id: member.id)&.slack_id
    end

    def deliver(member, requests, now:)
      key = "checkout_request_digest:#{member.id}:#{now.to_date.iso8601}"
      return unless REDIS.set(key, '1', nx: true, ex: KEY_TTL.to_i)

      begin
        slack_id = slack_id_for(member)
        if slack_id.present?
          response = Service::SlackConnector.send_slack_message(message(requests, now: now), slack_id)
          REDIS.set(last_key(member), now.to_i, ex: LAST_TTL.to_i)
          replace_previous(member, response, slack_id)
        end
      rescue => error
        REDIS.del(key)
        raise error
      end
    end
  end
end
