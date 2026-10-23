module Service
  # Members without a recurring Braintree subscription (one-time payment,
  # cash/check, a comped or class-granted membership, etc.) never receive any
  # automatic email as their membership approaches or passes expirationTime --
  # every existing renewal-adjacent email is driven off a Braintree
  # subscription webhook, which never fires for someone with no subscription
  # to begin with. This sends the two emails that gap is missing: a heads-up
  # a few days before expiration, and a notice once it's passed. A member
  # with a linked Slack account also gets a matching DM alongside the email.
  module MembershipExpirationNotice
    ZONE = ActiveSupport::TimeZone['America/New_York'].freeze
    REMINDER_DAYS_BEFORE = 3

    class << self
      def run!(at: Time.current)
        local_today = at.in_time_zone(ZONE).to_date
        excluded_ids = earned_membership_member_ids

        expiring_soon = candidates(excluded_ids, day: local_today + REMINDER_DAYS_BEFORE.days)
          .select { |member| member.membership_expiring_soon_notice_sent_for != member.expirationTime }
        expired = candidates(excluded_ids, day: local_today - 1.day)
          .select { |member| member.membership_expired_notice_sent_for != member.expirationTime }

        unless Rails.env.production?
          Rails.logger.info("expiring_soon: #{member_names(expiring_soon)}")
          Rails.logger.info("expired: #{member_names(expired)}")
        end

        expiring_soon.each { |member| notify!(member, :expiring_soon) }
        expired.each { |member| notify!(member, :expired) }

        { expiring_soon: expiring_soon.size, expired: expired.size }
      end

      private

      # A member currently earning their way to membership isn't paying at
      # all -- EarnedMembership#existing_subscription already keeps this
      # mutually exclusive with a Braintree subscription, so their status is
      # tracked and acted on through that system, not this one.
      def earned_membership_member_ids
        EarnedMembership.where(status: 'active').distinct(:member_id)
      end

      def candidates(excluded_ids, day:)
        start_ms = day.beginning_of_day.in_time_zone(ZONE).to_i * 1000
        end_ms = (day + 1.day).beginning_of_day.in_time_zone(ZONE).to_i * 1000

        Rails.logger.info("day: #{day}, start_ms: #{start_ms}, end_ms: #{end_ms}") unless Rails.env.production?

        Member.where(
          :firstname.ne => "Landlord", :lastname.ne => "Fob",
          :id.nin => excluded_ids,
          :status.in => Member::ACTIVE_MEMBERSHIP_STATUSES,
          :expirationTime.gte => start_ms,
          :expirationTime.lt => end_ms
        ).reject(&:active_membership_subscription?)
      end

      def member_names(members)
        members.map(&:fullname).join(',').presence || 'nil'
      end

      def notify!(member, kind)
        if kind == :expiring_soon
          MemberMailer.membership_expiring_soon(member.id.as_json).deliver_later
          member.update_attribute(:membership_expiring_soon_notice_sent_for, member.expirationTime)
        else
          MemberMailer.membership_expired(member.id.as_json).deliver_later
          member.update_attribute(:membership_expired_notice_sent_for, member.expirationTime)
        end
        notify_slack!(member, kind)
      rescue => error
        Service::ErrorReporter.notify(error, context: { member_id: member.id.to_s, kind: kind.to_s })
      end

      # Slack is a bonus channel alongside the email, not a replacement --
      # skip silently for anyone who hasn't linked a Slack account.
      def notify_slack!(member, kind)
        slack_id = member.slack_user&.slack_id
        return if slack_id.blank?

        expiration = member.membership_expires_at&.strftime('%B %-d, %Y')
        message = if kind == :expiring_soon
          "Hi #{member.firstname}, your Manchester Makerspace membership expires on #{expiration}. " \
            "Renew soon to keep your access to the space."
        else
          "Hi #{member.firstname}, your Manchester Makerspace membership expired on #{expiration}. " \
            "Your access to the space is on hold until you renew."
        end

        Service::SlackConnector.send_slack_message(message, slack_id)
      end
    end
  end
end
