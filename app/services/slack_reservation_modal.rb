class SlackReservationModal
  POLICY_TEXT_LIMIT = 2_900
  ALERT_TEXT_LIMIT = 200
  SCOPE_ACTION_ID = "reservation_scope_changed"
  TOOLS_ACTION_ID = "reservation_tools_changed"

  class << self
    def build(shop, member, **options)
      ReservationTiming.measure("slack_modal_build") do |metrics|
        build_view(shop, member, **options, metrics: metrics)
      end
    end

    def build_view(shop, member, response_url: nil, slack_user_id: nil, reservation_scope: nil, tool_ids: nil,
      title: nil, date: nil, start_time: nil, duration: nil, alert_message: nil, read_context: nil, metrics:)
      raise Error::UnprocessableEntity.new('This shop is out of service') if shop.out_of_service?
      read_context ||= ReservationReadContext.new(shop: shop, member: member)
      tools = read_context.eligible_tools
      groups = ToolGroup.where(shop_id: shop.id, archived: false, reservable: true).order_by(name: :asc).to_a.select do |group|
        group.included_tools.none? { |tool| tool.disabled? || tool.out_of_service? || (member.status == 'pending' && !tool.allow_pending) }
      end
      choices = tools.map { |tool| option(tool.name, tool.id.to_s) } + groups.map { |group| option(":linked_paperclips: #{group.name}", "group:#{group.id}") }
      raise ::Error::UnprocessableEntity.new("This shop has more than 100 reservable resources; use the portal") if choices.length > 100
      raise ::Error::UnprocessableEntity.new("This shop has no reservable resources") unless shop.reservable || choices.present?

      scope_options = []
      scope_options << option("Entire shop", "shop") if shop.reservable
      scope_options << option("One or more tools", "tools") if choices.present?
      reservation_scope = valid_scope(reservation_scope, scope_options)
      selected_tools = selected_tools(tools, reservation_scope, tool_ids)
      selected_groups = reservation_scope == "tools" ? groups.select { |group| Array(tool_ids).include?("group:#{group.id}") } : []
      selected_tools = (selected_tools + selected_groups.flat_map(&:included_tools)).uniq(&:id)
      resources = ReservationPolicy.resources(
        shop: shop, reservation_scope: reservation_scope, tools: selected_tools
      )
      group_prerequisite_ids = selected_groups.flat_map(&:prerequisite_ids).uniq
      required_ids = ReservationPolicy.prerequisite_ids(shop: shop, reservation_scope: reservation_scope,
        tools: selected_tools, member: member, additional_prerequisite_ids: group_prerequisite_ids)
      missing_ids = member.role == 'board_member' ? [] : required_ids.reject { |id| read_context.checked_out_tool_ids.include?(id) }
      missing_names = read_context.tool_names(missing_ids)
      prerequisite_warning = if missing_ids.any?
        "Missing required checkout(s): #{missing_ids.map { |id| missing_names[id] || id }.join(', ')}"
      end
      metrics[:resource_count] = resources.length
      policy = ReservationPolicy.aggregate(resources)
      scheduling_window = ReservationPolicy.scheduling_window(resources, policy: policy)
      durations = scheduling_window[:compatible] ? duration_options(policy) : []
      if scheduling_window[:compatible] && durations.empty?
        full_day_names = resources.select(&:reservation_full_day).map(&:name)
        limiting_names = resources.select do |resource|
          resource.max_reservation_duration_hours.to_f == policy[:maximum_duration_hours]
        end.map(&:name)
        scheduling_window = scheduling_window.merge(
          compatible: false,
          reason: "No duration is valid: #{full_day_names.join(', ')} require whole days, but " \
            "#{limiting_names.join(', ')} limit duration to #{format_hours(policy[:maximum_duration_hours])}."
        )
      end
      selected_duration = retained_duration(durations, duration)
      default_start = next_half_hour
      selected_date = valid_date(date) || default_start.to_date.iso8601
      selected_time = valid_time(start_time) || default_start.strftime("%H:%M")
      timing = reservation_timing(selected_date, selected_time, selected_duration)
      fee = fee_preview(resources, timing, read_context: read_context)

      blocks = [
        input("title", "title", "Title", { type: "plain_text_input", initial_value: title }.compact),
        input("scope", SCOPE_ACTION_ID, "Reserve", {
          type: "radio_buttons",
          options: scope_options,
          initial_option: scope_options.find { |choice| choice[:value] == reservation_scope }
        }, dispatch_action: true)
      ]
      if choices.present?
        tool_element = {
          type: "multi_static_select",
          action_id: TOOLS_ACTION_ID,
          placeholder: plain("Select tools"),
          options: choices
        }
        selected_values = tool_ids.nil? ? selected_tools.map { |tool| tool.id.to_s } : Array(tool_ids)
        initial_options = choices.select { |choice| selected_values.include?(choice[:value]) }
        tool_element[:initial_options] = initial_options if initial_options.present?
        blocks << input("tools", TOOLS_ACTION_ID, "Tools", tool_element, optional: reservation_scope != "tools", dispatch_action: true)
      end
      blocks << input("date", "date", "Date", {
          type: "datepicker",
          initial_date: selected_date
        })
      unless policy[:full_day]
        blocks << input("start_time", "start_time", "Start time", {
          type: "timepicker",
          initial_time: selected_time,
          timezone: "America/New_York"
        })
      end
      if durations.present?
        blocks << input("duration", "duration", "Duration", {
          type: "static_select",
          placeholder: plain("Select duration"),
          options: durations,
          initial_option: selected_duration
        })
      end
      blocks.concat(policy_blocks(
        shop, reservation_scope, selected_tools, member, policy, scheduling_window,
        timing: timing, fee: fee, alert_message: alert_message || prerequisite_warning, read_context: read_context,
        group_prerequisite_ids: group_prerequisite_ids
      ))

      view = {
        type: "modal",
        callback_id: "reservation_submit",
        notify_on_close: true,
        private_metadata: {
          shop_id: shop.id.to_s,
          member_id: member.id.to_s,
          response_url: response_url,
          slack_user_id: slack_user_id
        }.compact.to_json,
        title: plain("Reserve #{shop.name}".first(24)),
        close: plain("Cancel"),
        blocks: blocks
      }
      submit_text = if missing_ids.any? || !scheduling_window[:compatible] || durations.empty?
        "Review selection"
      elsif fee[:total].positive?
        "Use Member Portal"
      else
        "Reserve"
      end
      view[:submit] = plain(submit_text.first(24))
      view
    end
    private :build_view

    def update(shop:, member:, response_url:, slack_user_id:, reservation_scope:, tool_ids:,
      title:, date:, start_time:, duration:, alert_message: nil, read_context: nil)
      build(
        shop,
        member,
        read_context: read_context,
        response_url: response_url,
        slack_user_id: slack_user_id,
        reservation_scope: reservation_scope,
        tool_ids: tool_ids,
        title: title,
        date: date,
        start_time: start_time,
        duration: duration,
        alert_message: alert_message
      )
    end

    def policy_summary(shop:, reservation_scope:, tools:, member:, policy: nil, scheduling_window: nil, read_context: nil, group_prerequisite_ids: [])
      resources = ReservationPolicy.resources(
        shop: shop, reservation_scope: reservation_scope, tools: tools
      )
      policy ||= ReservationPolicy.aggregate(resources)
      return "Select one or more tools to see the effective reservation rules." if resources.empty?
      scheduling_window ||= ReservationPolicy.scheduling_window(resources, policy: policy)

      lines = ["*Effective reservation rules for #{resource_names(resources)}*"]
      lines << "• Book up to #{policy[:horizon_days]} #{'day'.pluralize(policy[:horizon_days])} ahead."
      lines << "• At least #{format_hours(policy[:minimum_advance_notice_hours])} advance notice."
      lines << "• Same-day reservations are not allowed." if policy[:prohibit_same_day]
      lines << "• Maximum duration: #{format_duration(policy[:maximum_duration_hours], policy[:full_day])}."
      lines << "• Reservations must use whole days (midnight to midnight)." if policy[:full_day]
      lines << "• Manager approval is required." if policy[:requires_approval]
      lines << "• *Unavailable combination:* #{scheduling_window[:reason]}" unless scheduling_window[:compatible]
      prerequisites = ReservationPolicy.prerequisite_names(
        shop: shop, reservation_scope: reservation_scope, tools: tools, member: member, read_context: read_context,
        additional_prerequisite_ids: group_prerequisite_ids
      )
      lines << if prerequisites.present?
        "• Required active checkout(s): #{prerequisites.join(', ')}."
      else
        "• No checkout prerequisites."
      end

      add_rule_differences(lines, resources)
      lines.join("\n").first(POLICY_TEXT_LIMIT)
    end

    private

    def valid_scope(requested, scope_options)
      values = scope_options.map { |choice| choice[:value] }
      values.include?(requested) ? requested : values.first
    end

    def selected_tools(tools, reservation_scope, tool_ids)
      return reservation_scope == "tools" ? tools.first(1) : [] if tool_ids.nil?

      ids = Array(tool_ids).map(&:to_s)
      selected = tools.select { |tool| ids.include?(tool.id.to_s) }
      selected
    end

    def duration_options(policy)
      maximum = policy[:maximum_duration_hours].to_f
      if policy[:full_day]
        1.upto([(maximum / 24).floor, 100].min).map do |days|
          option("#{days} #{'day'.pluralize(days)}", "days:#{days}")
        end
      else
        half_hours = (1..[(maximum * 2).floor, 10].min).map { |step| step / 2.0 }
        whole_hours = 6.upto([maximum.floor, 24].min).to_a
        two_hour_steps = maximum > 24 ? 26.step([maximum.floor, 48].min, 2).to_a : []
        four_hour_steps = maximum > 48 ? 52.step(maximum.floor, 4).to_a : []
        (half_hours + whole_hours + two_hour_steps + four_hour_steps).first(100).map do |hours|
          option(format_hours(hours), "hours:#{hours}")
        end
      end
    end

    def policy_blocks(shop, reservation_scope, tools, member, policy, scheduling_window, timing:, fee:, alert_message:, read_context:, group_prerequisite_ids: [])
      incompatible = !scheduling_window[:compatible]
      alert_text = alert_message.presence || if incompatible
        "These resources cannot currently be reserved together. Review the conflicting rules below."
      elsif fee[:total].positive?
        "Estimated fee: $#{format('%.2f', fee[:total])}. Review and confirm this reservation in the Member Portal."
      else
        "Review the effective reservation rules and calculated end time below."
      end
      blocks = [{
        type: "alert",
        block_id: "reservation_policy",
        level: (alert_message.present? || incompatible || fee[:total].positive?) ? "error" : "info",
        text: plain(alert_text.to_s.first(ALERT_TEXT_LIMIT))
      }, {
        type: "section",
        block_id: "reservation_policy_details",
        text: {
          type: "mrkdwn",
          text: policy_summary(
            shop: shop,
            reservation_scope: reservation_scope,
            tools: tools,
            member: member,
            policy: policy,
            scheduling_window: scheduling_window,
            read_context: read_context,
            group_prerequisite_ids: group_prerequisite_ids
          )
        }
      }]
      blocks << {
        type: "section",
        block_id: "reservation_calculated_end",
        text: { type: "mrkdwn", text: calculated_end_text(timing) }
      } if timing
      if fee[:total].positive?
        details = fee[:lines].map do |line|
          "• *#{line[:resourceName]}*: #{line[:units]} × #{line[:name]} ($#{format('%.2f', line[:amount])})"
        end
        blocks << {
          type: "section",
          block_id: "reservation_fee_preview",
          text: { type: "mrkdwn", text: (["*Estimated fee: $#{format('%.2f', fee[:total])}*"] + details +
            ["Confirm fees in the Member Portal before reserving."]).join("\n").first(POLICY_TEXT_LIMIT) }
        }
      end
      blocks
    end

    def reservation_timing(date, time, selected_duration)
      return unless selected_duration

      unit, amount = selected_duration[:value].split(":", 2)
      parsed_date = Date.iso8601(date)
      if unit == "days"
        start_at = ReservationService::ZONE.local(parsed_date.year, parsed_date.month, parsed_date.day)
        { start_at: start_at, end_at: start_at.advance(days: amount.to_i), full_day: true }
      else
        start_at = ReservationService::ZONE.parse("#{date} #{time}")
        { start_at: start_at, end_at: start_at + amount.to_f.hours, full_day: false }
      end
    rescue Date::Error, ArgumentError
      nil
    end

    def calculated_end_text(timing)
      ending = timing[:end_at].in_time_zone(ReservationService::ZONE)
      label = ending.strftime("%B %-d, %Y at %-I:%M %p %Z")
      suffix = timing[:full_day] ? " (exclusive end; whole-day reservation)" : ""
      "*Calculated end:* #{label}#{suffix}\n*Timezone:* America/New_York"
    end

    def fee_preview(resources, timing, read_context:)
      return { lines: [], total: 0.0 } unless timing && resources.present?
      return { lines: [], total: 0.0 } unless resources.all? { |resource| resource.respond_to?(:duration_fees) }

      snapshot = ReservationFeeService.snapshot({}, resources: resources, read_context: read_context)
      lines = ReservationFeeService.quote(
        resources: resources,
        start_at: timing[:start_at],
        end_at: timing[:end_at],
        full_day: timing[:full_day],
        rule_snapshot: snapshot
      )
      { lines: lines, total: ReservationFeeService.total(lines) }
    rescue ::Error::CustomError
      { lines: [], total: 0.0 }
    end

    def retained_duration(options, requested)
      return options.first if requested.blank?

      exact = options.find { |choice| choice[:value] == requested }
      return exact if exact

      requested_unit, requested_value = requested.to_s.split(":", 2)
      same_unit = options.select { |choice| choice[:value].start_with?("#{requested_unit}:") }
      return options.first if same_unit.empty?

      requested_amount = requested_value.to_f
      same_unit.reverse.find do |choice|
        choice[:value].split(":", 2).last.to_f <= requested_amount
      end || same_unit.first
    end

    def valid_date(value)
      Date.iso8601(value.to_s).iso8601 if value.present?
    rescue Date::Error
      nil
    end

    def valid_time(value)
      value if value.to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    end

    def add_rule_differences(lines, resources)
      return if resources.length < 2

      fields = {
        reservation_horizon_days: "booking window",
        minimum_advance_notice_hours: "advance notice",
        prohibit_same_day_reservations: "same-day rule",
        max_reservation_duration_hours: "maximum duration",
        reservation_full_day: "full-day rule",
        reservation_requires_approval: "approval rule"
      }
      differing = fields.select { |field, _label| resources.map { |resource| resource.public_send(field) }.uniq.length > 1 }
      return if differing.empty?

      lines << "• Rules differ by resource:"
      resources.each do |resource|
        details = differing.map do |field, label|
          "#{label} #{format_rule_value(field, resource.public_send(field))}"
        end
        lines << "  ◦ *#{resource.name}*: #{details.join('; ')}"
      end
    end

    def format_rule_value(field, value)
      case field
      when :reservation_horizon_days then "#{value}d"
      when :minimum_advance_notice_hours, :max_reservation_duration_hours then format_hours(value)
      else value ? "yes" : "no"
      end
    end

    def resource_names(resources)
      resources.map { |resource| "*#{resource.name}*" }.join(", ")
    end

    def format_duration(hours, full_day)
      return "#{(hours / 24).floor} #{'day'.pluralize((hours / 24).floor)}" if full_day && hours >= 24

      format_hours(hours)
    end

    def format_hours(hours)
      number = hours.to_f
      label = number == number.to_i ? number.to_i : number
      "#{label} #{'hour'.pluralize(number)}"
    end

    def plain(text)
      { type: "plain_text", text: text, emoji: true }
    end

    def option(text, value)
      { text: plain(text.first(75)), value: value }
    end

    def input(block_id, action_id, label, element, optional: false, dispatch_action: false)
      {
        type: "input",
        block_id: block_id,
        optional: optional,
        dispatch_action: dispatch_action,
        label: plain(label),
        element: element.merge(action_id: action_id)
      }
    end

    def next_half_hour
      now = Time.current.in_time_zone(ReservationService::ZONE)
      rounded_minute = now.min < 30 ? 30 : 0
      result = now.change(min: rounded_minute, sec: 0)
      rounded_minute.zero? ? result + 1.hour : result
    end
  end
end
