module Service
  module ReservationCalendar
    class << self
      def sync!(reservation)
        calendar_id = Service::GoogleWorkspace.reservations_calendar_id
        raise "GOOGLE_RESERVATIONS_CALENDAR_ID is not configured" if calendar_id.blank?

        if reservation.denied? || reservation.cancelled?
          delete_event(calendar_id, reservation)
          reservation.set(
            calendar_html_link: nil,
            calendar_sync_status: "deleted",
            calendar_sync_error: nil,
            calendar_synced_at: Time.current
          )
          return
        end

        event = build_event(reservation)
        result = upsert_event(calendar_id, event, reservation)
        reservation.set(
          calendar_event_id: result.id,
          calendar_html_link: result.html_link,
          calendar_sync_status: "synced",
          calendar_sync_error: nil,
          calendar_synced_at: Time.current
        )
      end

      private

      def upsert_event(calendar_id, event, reservation)
        service = Service::GoogleWorkspace.calendar
        begin
          service.get_event(calendar_id, event.id)
          write_event_with_label_recovery(
            calendar_id,
            event,
            reservation,
            event_id: event.id
          )
        rescue Google::Apis::ClientError => error
          raise unless error.status_code == 404

          write_event_with_label_recovery(
            calendar_id,
            event,
            reservation
          )
        end
      rescue => error
        Service::GoogleApiErrorReporter.report_if_permission_denied(
          error,
          operation: "reservation_calendar_upsert",
          resource_type: "Reservation",
          resource_id: event.id
        )
        raise
      end

      def write_event_with_label_recovery(calendar_id, event, reservation, event_id: nil)
        write_labeled_event(calendar_id, event, event_id: event_id)
      rescue Google::Apis::Error => initial_error
        raise unless invalid_event_label_error?(initial_error)

        begin
          Service::GoogleWorkspace.ensure_label!(reservation.shop)
          begin
            return write_labeled_event(calendar_id, event, event_id: event_id)
          rescue => retry_error
            log_label_recovery_failure(
              event,
              "retrying the event after recreating its label",
              retry_error
            )
          end
        rescue => label_error
          log_label_recovery_failure(event, "recreating the missing event label", label_error)
        end

        write_unlabeled_event(
          calendar_id,
          event_without_label(event),
          event_id: event_id
        )
      end

      def write_labeled_event(calendar_id, event, event_id: nil)
        if event_id
          Service::GoogleWorkspace.update_labeled_event(
            calendar_id,
            event_id,
            event,
            send_updates: "all"
          )
        else
          Service::GoogleWorkspace.insert_labeled_event(
            calendar_id,
            event,
            send_updates: "all"
          )
        end
      end

      def write_unlabeled_event(calendar_id, event, event_id: nil)
        if event_id
          Service::GoogleWorkspace.update_event(
            calendar_id,
            event_id,
            event,
            send_updates: "all"
          )
        else
          Service::GoogleWorkspace.insert_event(
            calendar_id,
            event,
            send_updates: "all"
          )
        end
      end

      def invalid_event_label_error?(error)
        [error.message, error.respond_to?(:body) ? error.body : nil]
          .compact
          .any? { |value| value.to_s.match?(/invalid:\s*invalid event label/i) }
      end

      def event_without_label(event)
        unlabeled_event = event.dup
        unlabeled_event.event_label_id = nil

        if event.extended_properties
          properties = event.extended_properties.dup
          properties.private = event.extended_properties.private.to_h.except(
            "makerspace_label_id"
          )
          unlabeled_event.extended_properties = properties
        end

        unlabeled_event
      end

      def log_label_recovery_failure(event, action, error)
        Rails.logger.warn(
          "[ReservationCalendar] Failed #{action} for reservation #{event.id}: " \
          "#{error.class}: #{error.message}; retrying without an event label"
        )
      end

      def delete_event(calendar_id, reservation)
        event_id = reservation.calendar_event_id.presence || reservation.id.to_s
        Service::GoogleWorkspace.calendar.delete_event(calendar_id, event_id, send_updates: "all")
      rescue Google::Apis::ClientError => error
        raise unless error.status_code == 404
      rescue => error
        Service::GoogleApiErrorReporter.report_if_permission_denied(
          error,
          operation: "reservation_calendar_delete",
          resource_type: "Reservation",
          resource_id: reservation.id
        )
        raise
      end

      def build_event(reservation)
        resource_emails = if reservation.reservation_scope == "shop"
          [reservation.shop.resource_email]
        else
          reservation.tools.map(&:resource_email)
        end.compact.uniq
        attendees = resource_emails.map do |email|
          Google::Apis::CalendarV3::EventAttendee.new(email: email, resource: true)
        end
        if reservation.member.deliverable_email?
          attendees << Google::Apis::CalendarV3::EventAttendee.new(
            email: reservation.member.email,
            display_name: reservation.member.fullname
          )
        end
        label_id = Service::GoogleWorkspace.label_id_for(reservation.shop.id)

        Google::Apis::CalendarV3::Event.new(
          id: reservation.id.to_s,
          summary: "#{reservation.status == "pending" ? "[Pending] " : ""}#{reservation.title}",
          description: [
            "Member: #{reservation.member.fullname}",
            "Reservation: #{reservation.id}",
            "Status: #{reservation.status}",
            "Resources: #{resource_names(reservation)}"
          ].join("\n"),
          start: Google::Apis::CalendarV3::EventDateTime.new(
            date_time: reservation.start_at.to_datetime,
            time_zone: ReservationService::ZONE.tzinfo.name
          ),
          end: Google::Apis::CalendarV3::EventDateTime.new(
            date_time: reservation.end_at.to_datetime,
            time_zone: ReservationService::ZONE.tzinfo.name
          ),
          attendees: attendees,
          color_id: reservation.shop.color_id.presence,
          event_label_id: label_id,
          extended_properties: Google::Apis::CalendarV3::Event::ExtendedProperties.new(
            private: {
              "makerspace_reservation_id" => reservation.id.to_s,
              "makerspace_shop_id" => reservation.shop.id.to_s,
              "makerspace_label_id" => label_id
            }
          )
        )
      end

      def resource_names(reservation)
        return reservation.shop.name if reservation.reservation_scope == "shop"
        "#{reservation.tools.map(&:name).join(', ')} in #{reservation.shop.name}"
      end
    end
  end
end
