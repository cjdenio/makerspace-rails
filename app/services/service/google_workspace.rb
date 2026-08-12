require "digest"

module Service
  module GoogleWorkspace
    DIRECTORY_SCOPE = "https://www.googleapis.com/auth/admin.directory.resource.calendar".freeze
    CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar".freeze
    DEFAULT_LABEL_COLOR = "#039be5".freeze
    CALENDAR_COLOR_CACHE_KEY = "google_calendar_colors:v6".freeze
    FALLBACK_CALENDAR_COLORS = [
      ["1",  "Lavender",  "#a4bdfc", "#1d1d1d"],
      ["2",  "Sage",      "#7ae7bf", "#1d1d1d"],
      ["3",  "Grape",     "#dbadff", "#1d1d1d"],
      ["4",  "Flamingo",  "#ff887c", "#1d1d1d"],
      ["5",  "Banana",    "#fbd75b", "#1d1d1d"],
      ["6",  "Tangerine", "#ffb878", "#1d1d1d"],
      ["7",  "Peacock",   "#46d6db", "#1d1d1d"],
      ["8",  "Graphite",  "#e1e1e1", "#1d1d1d"],
      ["9",  "Blueberry", "#5484ed", "#1d1d1d"],
      ["10", "Basil",     "#51b749", "#1d1d1d"],
      ["11", "Tomato",    "#dc2127", "#1d1d1d"]
    ].map do |id, name, background, foreground|
      {
        id: id,
        name: name,
        backgroundColor: background,
        foregroundColor: foreground
      }
    end.freeze

    class << self
      def authorization(scopes)
        Google::Auth::UserRefreshCredentials.new(
          client_id: ENV["GOOGLE_ID"],
          client_secret: ENV["GOOGLE_SECRET"],
          refresh_token: ENV["GOOGLE_TOKEN"],
          scope: Array(scopes)
        )
      end

      def directory
        service = Google::Apis::AdminDirectoryV1::DirectoryService.new
        service.authorization = authorization(DIRECTORY_SCOPE)
        service
      end

      def calendar
        service = Google::Apis::CalendarV3::CalendarService.new
        service.authorization = authorization(CALENDAR_SCOPE)
        service
      end

      def customer_id
        ENV["GOOGLE_CUSTOMER_ID"].presence || "my_customer"
      end

      def reservations_calendar_id
        ENV["GOOGLE_RESERVATIONS_CALENDAR_ID"].presence
      end

      def calendar_colors(include_color_id: nil)
        payload = read_color_cache || build_color_cache_payload
        colors = payload[:colors].map(&:dup)
        existing_id = include_color_id.to_s.presence

        if existing_id && colors.none? { |color| color[:id] == existing_id }
          existing = payload[:all_colors].find { |color| color[:id] == existing_id } ||
            FALLBACK_CALENDAR_COLORS.find { |color| color[:id] == existing_id }
          if existing
            colors << existing.dup
            payload[:colors] = colors
            write_color_cache(payload)
          end
        end

        colors
      end

      def ensure_resource!(record, category)
        execute_google_call(
          operation: "directory.calendarResources.ensure",
          resource_type: record.class.name,
          resource_id: record.id
        ) do
          ensure_resource_without_reporting!(record, category)
        end
      end

      def delete_resource!(resource_id, audit_resource_id: nil)
        return if resource_id.blank?

        execute_google_call(
          operation: "directory.calendarResources.delete",
          resource_type: "GoogleCalendarResource",
          resource_id: audit_resource_id
        ) do
          directory.delete_calendar_resource(customer_id, resource_id)
        end
      end

      def ensure_label!(record)
        calendar_id = reservations_calendar_id
        raise "GOOGLE_RESERVATIONS_CALENDAR_ID is not configured" if calendar_id.blank?

        execute_google_call(
          operation: "calendar.labels.ensure",
          resource_type: record.class.name,
          resource_id: record.id
        ) do
          calendar_record = calendar.get_calendar(calendar_id)
          label_properties = calendar_record.label_properties ||
            Google::Apis::CalendarV3::LabelProperties.new
          labels = Array(label_properties.event_labels)
          label_id = label_id_for(record.id)
          label = labels.find { |item| item.id == label_id }
          label ||= Google::Apis::CalendarV3::EventLabel.new(id: label_id)
          label.name = record.name.to_s.first(50)
          label.background_color = label_background_for(record)

          labels.reject! { |item| item.id == label_id }
          labels << label
          label_properties.event_labels = labels
          calendar_record.label_properties = label_properties
          calendar.update_calendar(calendar_id, calendar_record)
          label
        end
      end

      def delete_label!(label_source_id)
        return if label_source_id.blank? || reservations_calendar_id.blank?

        execute_google_call(
          operation: "calendar.labels.delete",
          resource_type: "GoogleCalendarLabel",
          resource_id: label_source_id
        ) do
          calendar_record = calendar.get_calendar(reservations_calendar_id)
          label_properties = calendar_record.label_properties
          next unless label_properties

          label_id = label_id_for(label_source_id)
          labels = Array(label_properties.event_labels)
          next unless labels.any? { |item| item.id == label_id }

          label_properties.event_labels = labels.reject { |item| item.id == label_id }
          calendar_record.label_properties = label_properties
          calendar.update_calendar(reservations_calendar_id, calendar_record)
        end
      end

      def label_id_for(object_id)
        digest = Digest::SHA256.hexdigest("makerspace-calendar-label:#{object_id}")[0, 32]
        digest[12] = "5"
        digest[16] = ((digest[16].to_i(16) & 0x3) | 0x8).to_s(16)
        "#{digest[0, 8]}-#{digest[8, 4]}-#{digest[12, 4]}-#{digest[16, 4]}-#{digest[20, 12]}"
      end

      def insert_labeled_event(calendar_id, event, send_updates: "all")
        execute_google_call(
          operation: "calendar.events.insert",
          resource_type: "Reservation",
          resource_id: event.id
        ) do
          service = calendar
          if service.method(:insert_event).parameters.any? { |_, name| name == :event_label_version }
            next service.insert_event(
              calendar_id,
              event,
              send_updates: send_updates,
              event_label_version: 1
            )
          end

          execute_labeled_event_command(
            service: service,
            method: :post,
            path: "calendars/{calendarId}/events",
            calendar_id: calendar_id,
            event: event,
            send_updates: send_updates
          )
        end
      end

      def update_labeled_event(calendar_id, event_id, event, send_updates: "all")
        execute_google_call(
          operation: "calendar.events.update",
          resource_type: "Reservation",
          resource_id: event.id
        ) do
          service = calendar
          if service.method(:update_event).parameters.any? { |_, name| name == :event_label_version }
            next service.update_event(
              calendar_id,
              event_id,
              event,
              send_updates: send_updates,
              event_label_version: 1
            )
          end

          execute_labeled_event_command(
            service: service,
            method: :put,
            path: "calendars/{calendarId}/events/{eventId}",
            calendar_id: calendar_id,
            event_id: event_id,
            event: event,
            send_updates: send_updates
          )
        end
      end

      def insert_event(calendar_id, event, send_updates: "all")
        execute_google_call(
          operation: "calendar.events.insert_without_label",
          resource_type: "Reservation",
          resource_id: event.id
        ) do
          calendar.insert_event(calendar_id, event, send_updates: send_updates)
        end
      end

      def update_event(calendar_id, event_id, event, send_updates: "all")
        execute_google_call(
          operation: "calendar.events.update_without_label",
          resource_type: "Reservation",
          resource_id: event.id
        ) do
          calendar.update_event(
            calendar_id,
            event_id,
            event,
            send_updates: send_updates
          )
        end
      end

      private

      def build_color_cache_payload
        all_colors = fetch_google_calendar_colors
        payload = {
          colors: all_colors.map(&:dup),
          all_colors: all_colors
        }
        write_color_cache(payload)
        payload
      rescue => error
        Service::GoogleApiErrorReporter.report_if_permission_denied(
          error,
          operation: "calendar.colors.get",
          resource_type: "GoogleCalendarColors"
        )
        Rails.logger.warn(
          "[GoogleCalendarColors] Using fallback palette after #{error.class}: #{error.message}"
        )
        payload = {
          colors: FALLBACK_CALENDAR_COLORS.map(&:dup),
          all_colors: FALLBACK_CALENDAR_COLORS.map(&:dup)
        }
        write_color_cache(payload)
        payload
      end

      def fetch_google_calendar_colors
        execute_google_call(operation: "calendar.colors.get") do
          service = calendar
          definitions = service.respond_to?(:get_colors) ?
            service.get_colors : service.get_color
          colors = definitions.event.to_h.map do |id, definition|
            fallback = FALLBACK_CALENDAR_COLORS.find { |color| color[:id] == id.to_s }
            {
              id: id.to_s,
              name: fallback&.dig(:name) || "Event color #{id}",
              backgroundColor: definition.background,
              foregroundColor: definition.foreground
            }
          end.sort_by { |definition| definition[:id].to_i }
          raise "Google Calendar returned no event colors" if colors.empty?

          colors
        end
      end

      def read_color_cache
        raw = REDIS.get(CALENDAR_COLOR_CACHE_KEY)
        return nil if raw.blank?

        parsed = JSON.parse(raw)
        colors = Array(parsed["colors"]).map { |color| symbolize_color(color) }
        all_colors = Array(parsed["allColors"] || parsed["all_colors"]).map { |color| symbolize_color(color) }
        return nil if colors.empty?

        { colors: colors, all_colors: all_colors.presence || colors.map(&:dup) }
      rescue Redis::BaseError, JSON::ParserError, TypeError => error
        Rails.logger.warn(
          "[GoogleCalendarColors] Ignoring unavailable/invalid Redis cache: " \
          "#{error.class}: #{error.message}"
        )
        nil
      end

      def write_color_cache(payload)
        REDIS.set(
          CALENDAR_COLOR_CACHE_KEY,
          JSON.generate(
            colors: payload[:colors],
            allColors: payload[:all_colors]
          )
        )
      rescue Redis::BaseError => error
        Rails.logger.warn(
          "[GoogleCalendarColors] Redis cache write failed: #{error.class}: #{error.message}"
        )
        nil
      end

      def symbolize_color(color)
        {
          id: color["id"].to_s,
          name: color["name"].to_s,
          backgroundColor: color["backgroundColor"].to_s,
          foregroundColor: color["foregroundColor"].to_s
        }
      end

      def execute_labeled_event_command(
        service:, method:, path:, calendar_id:, event:, send_updates:, event_id: nil
      )
        command = service.send(:make_simple_command, method, path, nil)
        command.request_representation = Google::Apis::CalendarV3::Event::Representation
        command.request_object = event
        command.response_representation = Google::Apis::CalendarV3::Event::Representation
        command.response_class = Google::Apis::CalendarV3::Event
        command.params["calendarId"] = calendar_id
        command.params["eventId"] = event_id if event_id
        command.query["sendUpdates"] = send_updates
        command.query["eventLabelVersion"] = 1
        service.send(:execute_or_queue_command, command)
      end

      def ensure_resource_without_reporting!(record, category)
        if record.google_resource_id.present?
          begin
            resource = directory.get_calendar_resource(customer_id, record.google_resource_id)
            if resource.resource_name != record.name
              resource.resource_name = record.name
              resource = directory.update_calendar_resource(customer_id, resource.resource_id, resource)
            end
            record.set(resource_email: resource.resource_email)
            return resource
          rescue Google::Apis::ClientError => error
            raise unless error.status_code == 404
          end
        end

        matches = calendar_resources.select do |resource|
          resource.resource_name.to_s.casecmp?(record.name.to_s) &&
            resource.resource_category.to_s.casecmp?(category.to_s)
        end

        raise "Multiple Google resources match #{record.name}" if matches.length > 1
        resource = matches.first || directory.calendar_resource(
          customer_id,
          Google::Apis::AdminDirectoryV1::CalendarResource.new(
            resource_id: record.id.to_s,
            resource_name: record.name,
            resource_category: category
          )
        )

        record.set(
          google_resource_id: resource.resource_id,
          resource_email: resource.resource_email
        )
        resource
      end

      def label_background_for(record)
        shop = record.is_a?(Shop) ? record : record.shop
        selected = calendar_colors(include_color_id: shop&.color_id).find do |definition|
          definition[:id] == shop&.color_id.to_s
        end
        selected&.fetch(:backgroundColor, nil) || DEFAULT_LABEL_COLOR
      end

      def calendar_resources
        resources = []
        page_token = nil
        loop do
          response = directory.list_calendar_resources(
            customer_id,
            max_results: 100,
            page_token: page_token
          )
          resources.concat(Array(response.items))
          page_token = response.next_page_token
          break if page_token.blank?
        end
        resources
      end

      def execute_google_call(operation:, resource_type: "GoogleApi", resource_id: nil)
        yield
      rescue Google::Apis::Error => error
        Service::GoogleApiErrorReporter.report_if_permission_denied(
          error,
          operation: operation,
          resource_type: resource_type,
          resource_id: resource_id
        )
        raise
      end
    end
  end
end
