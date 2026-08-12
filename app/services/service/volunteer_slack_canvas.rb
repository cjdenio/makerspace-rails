module Service
  module VolunteerSlackCanvas
    LOCK_TTL_SECONDS = 60

    class << self
      def sync!(shop, create_if_needed: false, sync_owner_access: false, struck_task_id: nil)
        return if shop.slack_channel.blank?

        tasks = available_tasks(shop)
        events = future_events(shop)
        struck_task = find_struck_task(shop, struck_task_id)
        return if shop.volunteer_canvas_id.blank? &&
          (!create_if_needed || (tasks.empty? && events.empty?))

        channel_id = Service::SlackConnector.find_channel_id(shop.slack_channel)
        if channel_id.blank?
          log_failure(
            "channel_not_found shop_id=#{shop.id} " \
            "slack_channel=#{shop.slack_channel.inspect}"
          )
          return
        end

        with_canvas_lock(shop.id) do
          shop.reload
          canvas_id = shop.volunteer_canvas_id.presence
          reused_canvas = canvas_id.present?
          owner_ids = nil

          if canvas_id.blank?
            owner_ids = Service::ReservationSlackCanvas.canvas_owner_slack_ids(shop)
            canvas_id = create_and_cache_canvas!(shop, channel_id, owner_ids)
          elsif sync_owner_access
            owner_ids = Service::ReservationSlackCanvas.canvas_owner_slack_ids(shop)
            set_owner_access!(canvas_id, owner_ids)
          end

          begin
            publish!(
              canvas_id,
              shop,
              tasks: tasks,
              events: events,
              struck_task: struck_task
            )
          rescue Slack::Web::Api::Errors::CanvasNotFound,
                 Slack::Web::Api::Errors::CanvasDeleted
            raise unless reused_canvas

            shop.set(volunteer_canvas_id: nil)
            owner_ids ||= Service::ReservationSlackCanvas.canvas_owner_slack_ids(shop)
            canvas_id = create_and_cache_canvas!(shop, channel_id, owner_ids)
            publish!(
              canvas_id,
              shop,
              tasks: tasks,
              events: events,
              struck_task: struck_task
            )
          end
        end
      end

      private

      def available_tasks(shop)
        VolunteerTask.claimable
          .where(parent_task_id: nil, shop_id: shop.id)
          .order_by(task_number: :asc)
          .to_a
      end

      def future_events(shop)
        VolunteerEvent.active_events
          .where(shop_id: shop.id, :event_date.gte => Date.current)
          .order_by(event_date: :asc, event_number: :asc)
          .to_a
      end

      def find_struck_task(shop, task_id)
        return if task_id.blank?

        task = VolunteerTask.find(task_id)
        task = task.parent_task if task.child_task?
        task if task&.shop_id.to_s == shop.id.to_s
      rescue Mongoid::Errors::DocumentNotFound
        nil
      end

      def create_and_cache_canvas!(shop, channel_id, owner_ids)
        title = "Volunteer in #{shop.name}"
        stderr_log(
          "create_start shop_id=#{shop.id} slack_channel=#{shop.slack_channel.inspect} " \
          "slack_channel_id=#{channel_id} title=#{title.inspect}"
        )
        canvas_id = Service::SlackConnector.create_canvas(
          title,
          channel_id: channel_id
        )
        raise "Slack did not return a volunteer canvas ID for #{shop.name}" if canvas_id.blank?

        set_owner_access!(canvas_id, owner_ids)
        shop.set(volunteer_canvas_id: canvas_id)
        stderr_log(
          "create_success shop_id=#{shop.id} canvas_id=#{canvas_id} " \
          "slack_channel=#{shop.slack_channel.inspect}"
        )
        canvas_id
      rescue => error
        log_failure(
          "create_failure shop_id=#{shop.id} slack_channel=#{shop.slack_channel.inspect} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        )
        raise
      end

      def set_owner_access!(canvas_id, owner_ids)
        Service::SlackConnector.set_canvas_user_access(
          canvas_id,
          owner_ids,
          access_level: "owner"
        )
      end

      def publish!(canvas_id, shop, tasks:, events:, struck_task:)
        markdown = canvas_markdown(
          shop,
          tasks: tasks,
          events: events,
          struck_task: struck_task
        )
        stderr_log(
          "write_start shop_id=#{shop.id} canvas_id=#{canvas_id} " \
          "slack_channel=#{shop.slack_channel.inspect} markdown_bytes=#{markdown.bytesize}"
        )
        Service::SlackConnector.replace_canvas(canvas_id, markdown)
        stderr_log(
          "write_success shop_id=#{shop.id} canvas_id=#{canvas_id} " \
          "slack_channel=#{shop.slack_channel.inspect} markdown_bytes=#{markdown.bytesize}"
        )
      rescue => error
        log_failure(
          "write_failure shop_id=#{shop.id} canvas_id=#{canvas_id} " \
          "slack_channel=#{shop.slack_channel.inspect} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        )
        raise
      end

      def canvas_markdown(shop, tasks:, events:, struck_task:)
        displayed_tasks = tasks.dup
        if struck_task && displayed_tasks.none? { |task| task.id == struck_task.id }
          displayed_tasks << struck_task
          displayed_tasks.sort_by!(&:task_number)
        end

        lines = [
          "# Volunteer in #{escape_markdown(shop.name)}",
          "## #{Date.current.strftime('%A, %B %-d, %Y')}",
          "",
          "Claim an opportunity in the member portal or use `/volunteer` in Slack.",
          "",
          "## Upcoming Volunteer Events"
        ]

        if events.empty?
          lines << "_No upcoming volunteer events._"
        else
          events.each { |event| lines << event_line(event) }
        end

        lines.concat(["", "## Available Volunteer Tasks"])
        if displayed_tasks.empty?
          lines << "_No volunteer tasks are currently available._"
        else
          displayed_tasks.each do |task|
            line = task_line(task)
            line = "~#{line}~" if struck_task&.id == task.id
            lines << line
          end
        end

        lines.concat([
          "",
          "## Ask your Resource Managers",
          "Ask a shop resource manager about other opportunities to volunteer."
        ])
        resource_manager_lines(shop).each { |line| lines << line }
        lines.concat([
          "",
          "_Last updated #{Time.current.in_time_zone(ReservationService::ZONE).strftime('%B %-d, %Y at %H:%M %Z')}._"
        ])
        lines.join("\n")
      end

      def event_line(event)
        date = event.event_date&.strftime("%b %-d, %Y") || "Date to be announced"
        details = [
          "- **#{escape_markdown(event.display_number)} — #{escape_markdown(event.title)}**",
          date,
          credit_label(event.credit_value)
        ]
        prerequisites = prerequisite_label(event)
        details << prerequisites if prerequisites.present?
        details.join(" — ")
      end

      def task_line(task)
        details = [
          "- **#{escape_markdown(task.display_number)} — #{escape_markdown(task.title)}**",
          credit_label(task.credit_value)
        ]
        prerequisites = prerequisite_label(task)
        details << prerequisites if prerequisites.present?
        details.join(" — ")
      end

      def prerequisite_label(record)
        names = record.prerequisite_tools.map(&:name)
        return if names.empty?

        "Requires: #{names.map { |name| escape_markdown(name) }.join(', ')}"
      end

      def credit_label(value)
        number = value.to_f
        formatted = number == number.to_i ? number.to_i : number
        "#{formatted} volunteer #{number == 1 ? 'credit' : 'credits'}"
      end

      def resource_manager_lines(shop)
        managers = Member.where(
          role: "resource_manager",
          :resource_manager_shop_ids.in => [shop.id.to_s]
        ).to_a.sort_by do |member|
          [member.lastname.to_s.downcase, member.firstname.to_s.downcase]
        end
        return ["- _No resource managers are currently assigned._"] if managers.empty?

        slack_ids = SlackUser.where(:member_id.in => managers.map(&:id))
          .to_a
          .index_by { |slack_user| slack_user.member_id.to_s }
        managers.map do |manager|
          slack_id = slack_ids[manager.id.to_s]&.slack_id
          slack_label = slack_id.present? ? "<@#{slack_id}>" : "Slack ID not linked"
          "- #{escape_markdown(manager.fullname)} — #{slack_label}"
        end
      end

      def escape_markdown(value)
        value.to_s.gsub(/([\\`*_{}\[\]()#+.!-])/) { |match| "\\#{match}" }
      end

      def stderr_log(message)
        $stderr.puts("[VolunteerSlackCanvas] #{message}")
      end

      def log_failure(message)
        formatted = "[VolunteerSlackCanvas] #{message}"
        $stderr.puts(formatted)
        Rails.logger.error(formatted)
      end

      def with_canvas_lock(shop_id)
        key = "volunteer_canvas_lock/shop/#{shop_id}"
        token = SecureRandom.uuid
        acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
        raise "Slack volunteer canvas synchronization is busy" unless acquired

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
              "[VolunteerSlackCanvasLockReleaseError] key=#{key} " \
              "error=#{error.class}: #{error.message}"
            )
          end
        end
      end
    end
  end
end
