module Service
  module ReservationSlackCanvas
    LOCK_TTL_SECONDS = 60
    RATE_LIMIT_MAX_RETRIES = 5

    class << self
      def rebuild_all!
        today = Time.current.in_time_zone(ReservationService::ZONE).to_date
        dates = [today.iso8601, (today + 1.day).iso8601]
        failures = []

        Shop.all.each do |shop|
          begin
            rebuild_shop_with_rate_limit_retry!(shop, dates)
          rescue => error
            log_rebuild_failure(shop, dates, error)
            failures << "#{shop.id}: #{error.class}: #{error.message}"
          end
        end

        return if failures.empty?

        raise "Slack canvas rebuild failed for #{failures.join('; ')}"
      end

      def sync!(shop, dates:, sync_owner_access: false)
        return if shop.slack_channel.blank?

        channel_id = Service::SlackConnector.find_channel_id(shop.slack_channel)
        if channel_id.blank?
          Rails.logger.error(
            "[ReservationSlackCanvasChannelNotFound] shop_id=#{shop.id} " \
            "slack_channel=#{shop.slack_channel.inspect}"
          )
          return
        end

        today = Time.current.in_time_zone(ReservationService::ZONE).to_date
        tomorrow = today + 1.day
        requested_dates = Array(dates).filter_map { |value| parse_date(value) }.uniq
        owner_slack_ids = nil

        requested_dates.each do |date|
          configuration = canvas_configuration(date, today, tomorrow, shop)
          next unless configuration

          field, title = configuration
          with_canvas_lock(shop.id, field) do
            shop.reload
            canvas_id = shop.public_send(field).presence
            reused_canvas = canvas_id.present?
            if canvas_id.blank?
              owner_slack_ids ||= canvas_owner_slack_ids(shop)
              canvas_id = create_and_cache_canvas!(
                shop,
                field,
                title,
                owner_slack_ids
              )
            end

            begin
              if sync_owner_access && reused_canvas
                owner_slack_ids ||= canvas_owner_slack_ids(shop)
                set_canvas_owner_access!(canvas_id, owner_slack_ids)
              end
              publish_agenda!(canvas_id, channel_id, shop, date)
            rescue Slack::Web::Api::Errors::CanvasNotFound,
                   Slack::Web::Api::Errors::CanvasDeleted
              raise unless reused_canvas

              shop.set(field => nil)
              owner_slack_ids ||= canvas_owner_slack_ids(shop)
              canvas_id = create_and_cache_canvas!(
                shop,
                field,
                title,
                owner_slack_ids
              )
              publish_agenda!(canvas_id, channel_id, shop, date)
            end
          end
        end
      end

      def canvas_owner_slack_ids(shop)
        member_ids = Member.any_of(
          { :role.in => %w[admin board_member] },
          {
            role: "resource_manager",
            :resource_manager_shop_ids.in => [shop.id.to_s]
          }
        ).pluck(:id)

        SlackUser.where(:member_id.in => member_ids)
          .pluck(:slack_id)
          .map(&:to_s)
          .reject(&:blank?)
          .uniq
      end

      def sync_member_access!(member, shop_ids:)
        slack_id = member.slack_user&.slack_id.to_s
        return if slack_id.blank?

        Shop.where(:id.in => Array(shop_ids)).each do |shop|
          access_level = canvas_owner?(member, shop) ? "owner" : "read"
          canvas_ids(shop).each do |canvas_id|
            Service::SlackConnector.set_canvas_user_access(
              canvas_id,
              [slack_id],
              access_level: access_level
            )
          end
        end
      end

      private

      def rebuild_shop_with_rate_limit_retry!(shop, dates)
        retries = 0
        begin
          if shop.canvas_today.present? ||
              shop.canvas_tomorrow.present? ||
              reservation_canvas_relevant?(shop, dates)
            sync!(
              shop,
              dates: dates,
              sync_owner_access: true
            )
          end
          Service::VolunteerSlackCanvas.sync!(
            shop,
            create_if_needed: true,
            sync_owner_access: true
          )
        rescue Slack::Web::Api::Errors::TooManyRequestsError => error
          raise if retries >= RATE_LIMIT_MAX_RETRIES

          retries += 1
          retry_after = error.retry_after.to_i
          message = "[ReservationSlackCanvasRateLimited] shop_id=#{shop.id} " \
            "slack_channel=#{shop.slack_channel.inspect} " \
            "retry=#{retries}/#{RATE_LIMIT_MAX_RETRIES} " \
            "retry_after=#{retry_after}"
          $stderr.puts(message)
          Rails.logger.warn(message)
          sleep(retry_after)
          retry
        end
      end

      def reservation_canvas_relevant?(shop, dates)
        requested_dates = Array(dates).filter_map { |value| parse_date(value) }
        return false if requested_dates.empty?

        first_date = requested_dates.min
        last_date = requested_dates.max + 1.day
        window_start = ReservationService::ZONE.local(
          first_date.year,
          first_date.month,
          first_date.day
        ).utc
        window_end = ReservationService::ZONE.local(
          last_date.year,
          last_date.month,
          last_date.day
        ).utc

        return true if Reservation.blocking.where(
          shop_id: shop.id,
          :start_at.lt => window_end,
          :end_at.gt => window_start
        ).exists?

        ReservationBlackout.occurrences_overlapping(
          shop_id: shop.id,
          start_at: window_start,
          end_at: window_end
        ).present?
      end

      def log_rebuild_failure(shop, dates, error)
        message = "[ReservationSlackCanvasRebuildError] shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} " \
          "dates=#{dates.join(',')} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        $stderr.puts(message)
        Rails.logger.error(message)
        Honeybadger.notify(error) if defined?(Honeybadger)
      end

      def canvas_owner?(member, shop)
        return true if %w[admin board_member].include?(member.role)

        member.role == "resource_manager" &&
          Array(member.resource_manager_shop_ids).map(&:to_s).include?(shop.id.to_s)
      end

      def canvas_ids(shop)
        [
          shop.canvas_today,
          shop.canvas_tomorrow,
          shop.volunteer_canvas_id
        ].compact_blank.uniq
      end

      def canvas_configuration(date, today, tomorrow, shop)
        return [:canvas_today, "Today's #{shop.name} Reservations"] if date == today
        return [:canvas_tomorrow, "Tomorrow's #{shop.name} Reservations"] if date == tomorrow

        nil
      end

      def parse_date(value)
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end

      def create_and_cache_canvas!(shop, field, title, owner_slack_ids)
        stderr_log(
          "create_start shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} field=#{field} " \
          "title=#{title.inspect}"
        )
        canvas_id = Service::SlackConnector.create_canvas(title)
        raise "Slack did not return a canvas ID for #{title}" if canvas_id.blank?

        set_canvas_owner_access!(canvas_id, owner_slack_ids)
        shop.set(field => canvas_id)
        stderr_log(
          "create_success shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} field=#{field} " \
          "canvas_id=#{canvas_id}"
        )
        canvas_id
      rescue => error
        failure_log(
          "create_failure shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} field=#{field} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        )
        raise
      end

      def set_canvas_owner_access!(canvas_id, owner_slack_ids)
        Service::SlackConnector.set_canvas_user_access(
          canvas_id,
          owner_slack_ids,
          access_level: "owner"
        )
      end

      def publish_agenda!(canvas_id, channel_id, shop, date)
        phase = "write"
        markdown = agenda_markdown(shop, date)
        phase = "access"
        stderr_log(
          "access_start shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} " \
          "slack_channel_id=#{channel_id} canvas_id=#{canvas_id} date=#{date}"
        )
        Service::SlackConnector.set_canvas_channel_access(canvas_id, channel_id)
        stderr_log(
          "access_success shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} " \
          "slack_channel_id=#{channel_id} canvas_id=#{canvas_id} date=#{date}"
        )
        phase = "write"
        stderr_log(
          "write_start shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} canvas_id=#{canvas_id} " \
          "date=#{date} markdown_bytes=#{markdown.bytesize}"
        )
        Service::SlackConnector.replace_canvas(canvas_id, markdown)
        stderr_log(
          "write_success shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} canvas_id=#{canvas_id} " \
          "date=#{date} markdown_bytes=#{markdown.bytesize}"
        )
      rescue => error
        failure_log(
          "#{phase}_failure shop_id=#{shop.id} " \
          "slack_channel=#{shop.slack_channel.inspect} canvas_id=#{canvas_id} " \
          "date=#{date} error=#{Service::SlackConnector.format_api_error(error)}"
        )
        raise
      end

      def agenda_markdown(shop, date)
        day_start = ReservationService::ZONE.local(
          date.year,
          date.month,
          date.day
        ).utc
        next_date = date + 1.day
        day_end = ReservationService::ZONE.local(
          next_date.year,
          next_date.month,
          next_date.day
        ).utc
        reservations = Reservation.blocking
          .where(
            shop_id: shop.id,
            :start_at.lt => day_end,
            :end_at.gt => day_start
          )
          .order_by(start_at: :asc)
          .to_a
        blackouts = ReservationBlackout.occurrences_overlapping(
          shop_id: shop.id,
          start_at: day_start,
          end_at: day_end
        )
        agenda_items = reservations.map do |reservation|
          {
            kind: :reservation,
            start_at: reservation.start_at,
            reservation: reservation
          }
        end + blackouts.map do |occurrence|
          {
            kind: :blackout,
            start_at: occurrence[:start_at],
            occurrence: occurrence
          }
        end
        agenda_items.sort_by! { |item| item[:start_at] }

        lines = [
          "# #{escape_markdown(shop.name)} Reservations",
          "## #{date.strftime('%A, %B %-d, %Y')}",
          ""
        ]

        if agenda_items.empty?
          lines << "_No pending or approved reservations._"
        else
          lines.concat([
            "| Time | Reservation | Member | Resources | Status |",
            "| --- | --- | --- | --- | --- |"
          ])
          agenda_items.each do |item|
            cells = if item[:kind] == :blackout
              occurrence = item[:occurrence]
              [
                period_time(occurrence[:start_at], occurrence[:end_at]),
                escape_table_cell(
                  "No Reservations Available: #{occurrence[:blackout].title}"
                ),
                "",
                "Entire shop",
                "Unavailable"
              ]
            else
              reservation = item[:reservation]
              [
                reservation_time(reservation),
                reservation_title(reservation),
                escape_table_cell(reservation.member&.fullname),
                escape_table_cell(resource_names(reservation)),
                escape_table_cell(reservation.status.to_s.titleize)
              ]
            end
            lines << "| #{cells.join(' | ')} |"
          end
        end

        lines.concat([
          "",
          "_Last updated #{Time.current.in_time_zone(ReservationService::ZONE).strftime('%B %-d, %Y at %H:%M %Z')}._"
        ]).join("\n")
      end

      def reservation_time(reservation)
        period_time(reservation.start_at, reservation.end_at)
      end

      def period_time(period_start, period_end)
        start_at = period_start.in_time_zone(ReservationService::ZONE)
        end_at = period_end.in_time_zone(ReservationService::ZONE)
        if start_at.to_date == end_at.to_date
          "#{start_at.strftime('%H:%M')}-#{end_at.strftime('%H:%M')}"
        else
          "#{start_at.strftime('%b %-d %H:%M')}-#{end_at.strftime('%b %-d %H:%M')}"
        end
      end

      def reservation_title(reservation)
        title = escape_table_cell(reservation.title)
        return title if reservation.calendar_html_link.blank?

        "[#{title}](#{reservation.calendar_html_link})"
      end

      def resource_names(reservation)
        return "Entire shop" if reservation.reservation_scope == "shop"

        reservation.tools.map(&:name).join(", ")
      end

      def escape_markdown(value)
        value.to_s.gsub(/([\\`*_{}\[\]()#+.!-])/) { |match| "\\#{match}" }
      end

      def escape_table_cell(value)
        value.to_s.gsub(/\s+/, " ").gsub("|", "\\|").strip
      end

      def stderr_log(message)
        $stderr.puts("[ReservationSlackCanvas] #{message}")
      end

      def failure_log(message)
        formatted = "[ReservationSlackCanvas] #{message}"
        $stderr.puts(formatted)
        Rails.logger.error(formatted)
      end

      def with_canvas_lock(shop_id, field)
        key = "reservation_canvas_lock/shop/#{shop_id}/#{field}"
        token = SecureRandom.uuid
        acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
        raise "Slack reservation canvas synchronization is busy" unless acquired

        yield
      ensure
        if key && token
          begin
            REDIS.eval(
              "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
              keys: [key],
              argv: [token]
            )
          rescue Redis::BaseError => error
            Rails.logger.warn(
              "[ReservationSlackCanvasLockReleaseError] key=#{key} " \
              "error=#{error.class}: #{error.message}"
            )
          end
        end
      end
    end
  end
end
