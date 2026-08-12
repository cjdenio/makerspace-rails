module Service
  module ReservationSlackReminder
    MINIMUM_START_LEAD_TIME = 6.hours
    LONG_RANGE_START_LEAD_TIME = 47.hours
    STANDARD_REMINDER_LEAD_TIME = 30.minutes
    LONG_RANGE_REMINDER_LEAD_TIME = 8.hours

    class << self
      def sync!(reservation)
        slack_id = reservation.member&.slack_user&.slack_id.to_s

        unless schedulable?(reservation, slack_id)
          delete!(reservation, slack_id: slack_id)
          return
        end

        delete!(reservation, slack_id: slack_id)
        schedule!(reservation, slack_id: slack_id)
      end

      private

      def schedulable?(reservation, slack_id)
        return false unless reservation.status == "approved"
        return false if slack_id.blank?
        return false if reservation.member.direct_notifications_suppressed?

        start_lead_time = reservation.start_at - Time.current
        eligible_start_window =
          start_lead_time >= MINIMUM_START_LEAD_TIME ||
          reservation.scheduled_message_id.present?
        eligible_start_window && reminder_time(reservation) > Time.current
      end

      def schedule!(reservation, slack_id:)
        post_at = reminder_time(reservation)
        scheduled_message_id = Service::SlackConnector.schedule_slack_message(
          channel: slack_id,
          text: reminder_text(reservation),
          post_at: post_at
        )
        if scheduled_message_id.blank?
          raise "Slack did not return a scheduled_message_id"
        end

        reservation.set(
          scheduled_message_id: scheduled_message_id,
          scheduled_message_channel_id: slack_id
        )
        Rails.logger.info(
          "[ReservationSlackReminderScheduled] reservation_id=#{reservation.id} " \
          "member_id=#{reservation.member_id} scheduled_message_id=#{scheduled_message_id} " \
          "post_at=#{post_at.utc.iso8601}"
        )
      end

      def delete!(reservation, slack_id:)
        scheduled_message_id = reservation.scheduled_message_id.to_s
        return if scheduled_message_id.blank?

        channel_id = reservation.scheduled_message_channel_id.presence || slack_id
        if channel_id.blank?
          raise "Cannot delete scheduled Slack reminder because the member has no linked Slack ID"
        end

        begin
          Service::SlackConnector.delete_scheduled_slack_message(
            channel: channel_id,
            scheduled_message_id: scheduled_message_id
          )
        rescue Slack::Web::Api::Errors::SlackError => error
          raise unless error.message.to_s.include?("invalid_scheduled_message_id")

          Rails.logger.info(
            "[ReservationSlackReminderAlreadyDelivered] reservation_id=#{reservation.id} " \
            "scheduled_message_id=#{scheduled_message_id}"
          )
        end
        reservation.set(
          scheduled_message_id: nil,
          scheduled_message_channel_id: nil
        )
        Rails.logger.info(
          "[ReservationSlackReminderDeleted] reservation_id=#{reservation.id} " \
          "member_id=#{reservation.member_id} scheduled_message_id=#{scheduled_message_id}"
        )
      end

      def reminder_time(reservation)
        start_lead_time = reservation.start_at - Time.current
        reminder_lead_time = start_lead_time > LONG_RANGE_START_LEAD_TIME ?
          LONG_RANGE_REMINDER_LEAD_TIME :
          STANDARD_REMINDER_LEAD_TIME
        reservation.start_at - reminder_lead_time
      end

      def reminder_text(reservation)
        start_at = reservation.start_at.in_time_zone(ReservationService::ZONE)
        end_at = reservation.end_at.in_time_zone(ReservationService::ZONE)
        resources = if reservation.reservation_scope == "shop"
          "Entire #{reservation.shop.name}"
        else
          "#{reservation.tools.map(&:name).join(', ')} in #{reservation.shop.name}"
        end

        Service::EmailTemplate.render(
          :reservation_reminder,
          Service::EmailTemplate.common_variables(reservation.member).merge(
            reservation_title: reservation.title,
            reservation_time: time_range(start_at, end_at),
            resources: resources,
            reservations_url: portal_reservations_url
          ),
          fallback: true,
          format: :text
        )
      end

      def time_range(start_at, end_at)
        if start_at.to_date == end_at.to_date
          "#{start_at.strftime('%b %-d, %Y %H:%M')}–#{end_at.strftime('%H:%M %Z')}"
        else
          "#{start_at.strftime('%b %-d, %Y %H:%M %Z')}–" \
            "#{end_at.strftime('%b %-d, %Y %H:%M %Z')}"
        end
      end

      def portal_reservations_url
        options = Rails.application.config.action_mailer.default_url_options || {}
        controller_options =
          Rails.application.config.action_controller.default_url_options || {}
        host = options[:host].presence || controller_options[:host].presence || "localhost"
        base_url = AppDomainUrl.base_url(host, environment: Rails.env)
        port = options[:port].presence || controller_options[:port].presence
        base_uri = URI.parse(base_url)
        default_port = URI.parse("#{base_uri.scheme}://example.test").port
        if port && base_uri.port == default_port
          base_url = "#{base_url}:#{port}"
        end
        "#{base_url}/reservations"
      end
    end
  end
end
