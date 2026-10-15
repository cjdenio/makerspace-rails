class Slack::InteractionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    slack_request = nil
    payload = JSON.parse(params[:payload].to_s)
    if payload['action_id'].to_s.start_with?('fix_') || payload.dig('view', 'callback_id').to_s.start_with?('fix_') || Array(payload['actions']).any? { |a| a['action_id'].to_s.start_with?('fix_') }
      return render json: FixSlack.interaction(payload)
    end

    callback_id = payload.dig("view", "callback_id")
    if callback_id == SlackCheckoutModal::CALLBACK_ID && payload["type"].in?(%w[block_actions view_submission])
      return checkout_modal_interaction(payload)
    end
    supported = payload["type"] == "view_submission" ||
      (payload["type"].in?(%w[view_closed block_actions]) && callback_id == "reservation_submit")
    return render json: {} unless supported

    case callback_id
    when "reservation_submit"
      if payload["type"] == "view_closed"
        close_reservation(payload)
      elsif payload["type"] == "block_actions"
        if reservation_policy_action?(payload)
          update_reservation_modal(payload)
        else
          render json: {}
        end
      else
        create_reservation(payload)
      end
    when "checkout_request_submit"
      create_checkout_request(payload)
    when "group_checkout_approve"
      approve_group_checkout(payload)
    else
      render json: {}
    end
  end

  private

  def approve_group_checkout(payload)
    SlackGroupApprovalModal.submit!(payload)
    render json: { response_action: "clear" }
  rescue Error::CustomError => error
    render json: { response_action: "update", view: {
      type: "modal", callback_id: "group_checkout_result", title: { type: "plain_text", text: "Group checkout" },
      close: { type: "plain_text", text: "Close" },
      blocks: [{ type: "section", text: { type: "plain_text", text: "#{error.message} Reopen the command to review the current group." } }]
    } }
  end

  def checkout_modal_interaction(payload)
    workflow = SlackCheckoutWorkflow.new(payload)
    view = workflow.call
    return render json: { response_action: "clear" } if view == :clear
    deliver_checkout_view(payload, view)
  rescue SlackCheckoutWorkflow::FieldError => error
    render json: { response_action: "errors", errors: { error.field => error.message } }
  rescue SlackCheckoutWorkflow::Rejected, Error::Forbidden, Error::UnprocessableEntity => error
    view = workflow ? workflow.alert(error.message) : SlackCheckoutModal.new(metadata: { "step" => "alert" }, alert: error.message).build
    deliver_checkout_view(payload, view)
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "checkout modal interaction" })
    view = SlackCheckoutModal.new(metadata: { "step" => "alert" },
      alert: "The checkout could not be updated. Reopen /checkout to check its current status before trying again.").build
    deliver_checkout_view(payload, view)
  end

  def deliver_checkout_view(payload, view)
    if payload["type"] == "view_submission"
      return render json: { response_action: "update", view: view }
    end
    if payload.dig("view", "id").blank? || payload.dig("view", "hash").blank?
      raise SlackCheckoutWorkflow::Rejected, "The checkout view is missing its concurrency token."
    end
    Service::SlackConnector.update_modal(payload.dig("view", "id"), view, hash: payload.dig("view", "hash"))
    render json: {}
  rescue => error
    # Never retry views.update without its hash: the user may already have moved
    # on in another interaction. A new alert leaves that newer view untouched.
    Service::ErrorReporter.notify(error, context: { phase: "checkout modal views.update" })
    begin
      alert = SlackCheckoutModal.new(metadata: { "step" => "alert" },
        alert: "The checkout view changed or could not be refreshed. Close this form and reopen /checkout.").build
      Service::SlackConnector.open_modal(payload["trigger_id"], alert) if payload["trigger_id"].present?
    rescue => fallback_error
      Service::ErrorReporter.notify(fallback_error, context: { phase: "checkout modal update fallback" })
    end
    render json: {}
  end

  def create_reservation(payload)
    slack_request = nil
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    member = Member.find(metadata["member_id"])
    scope = selected_scope(state)
    tool_ids = selected_tool_ids(state)
    if scope == "tools"
      shop = Shop.find(metadata["shop_id"])
      validate_reservation_tool_ids!(shop, member, tool_ids)
      expanded = ReservationGroupExpansion.call(shop_id: shop.id, reservation_scope: 'tools',
        tool_ids: tool_ids.reject { |id| id.start_with?('group:') },
        tool_group_ids: tool_ids.grep(/\Agroup:/).map { |id| id.delete_prefix('group:') })
      tools = Tool.where(:id.in => expanded[:tool_ids]).to_a
      scheduling_window = ReservationPolicy.scheduling_window(tools)
      unless scheduling_window[:compatible]
        return render json: {
          response_action: "errors",
          errors: { "tools" => scheduling_window[:reason].to_s.first(150) }
        }
      end
    elsif (shop = Shop.find_by(id: metadata["shop_id"]))
      scheduling_window = ReservationPolicy.scheduling_window([shop])
      unless scheduling_window[:compatible]
        return render json: {
          response_action: "errors",
          errors: { "scope" => scheduling_window[:reason].to_s.first(150) }
        }
      end
    end
    date = state.dig("date", "date", "selected_date")
    start_text = state.dig("start_time", "start_time", "selected_time")
    duration = parse_reservation_duration(state.dig("duration", "duration", "selected_option", "value"))
    parsed_date = Date.iso8601(date.to_s)
    if duration[:full_day]
      start_at = ReservationService::ZONE.local(parsed_date.year, parsed_date.month, parsed_date.day)
      end_at = start_at.advance(days: duration[:days])
    else
      start_at = ReservationService::ZONE.parse("#{date} #{start_text}")
      end_at = start_at + duration[:hours].hours
    end

    reservation = ReservationService.create!(
      member: member,
      source: "slack",
      attributes: {
        title: state.dig("title", "title", "value"),
        shop_id: metadata["shop_id"],
        reservation_scope: scope,
        tool_ids: tool_ids.reject { |id| id.start_with?('group:') },
        tool_group_ids: tool_ids.grep(/\Agroup:/).map { |id| id.delete_prefix('group:') },
        full_day: duration[:full_day],
        start_at: start_at,
        end_at: end_at
      }
    )

    message = reservation_outcome(reservation)
    if reservation.status == "pending" && reservation.effective_approval_details.present?
      reasons = reservation.effective_approval_details.map { |detail| "• #{detail['message']}" }
      message += "\nApproval required because:\n#{reasons.join("\n")}"
    end
    enqueue_reservation_outcome(message, metadata, payload)
    render json: { response_action: "clear" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=create member_id=#{member&.id} reason=#{error.message}"
    )
    field = reservation_error_field(error.message, state)
    if field
      render json: { response_action: "errors", errors: { field => error.message.to_s.first(150) } }
    else
      render_reservation_alert(payload, error.message)
    end
  rescue Date::Error
    render json: { response_action: "errors", errors: { "date" => "Select a valid reservation date." } }
  rescue => error
    Rails.logger.error(
      "[SlackReservationError] action=create member_id=#{member&.id} " \
      "error=#{Service::SlackConnector.format_api_error(error, request: slack_request)}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render_reservation_alert(
      payload,
      "The reservation could not be created. Verify the details or use the Member Portal."
    )
  end

  def update_reservation_modal(payload)
    ReservationTiming.measure("slack_modal_update") do |metrics|
      update_reservation_modal_view(payload, metrics)
    end
  end

  def update_reservation_modal_view(payload, metrics)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    action = payload.fetch("actions").first
    scope = selected_scope(state)
    scope = action.dig("selected_option", "value") if action["action_id"] == SlackReservationModal::SCOPE_ACTION_ID
    tool_ids = selected_tool_ids(state)
    if action["action_id"] == SlackReservationModal::TOOLS_ACTION_ID
      tool_ids = Array(action["selected_options"]).map { |option| option["value"] }
    end
    shop = Shop.find(metadata["shop_id"])
    member = Member.find(metadata["member_id"])
    metrics[:resource_count] = scope == "shop" ? 1 : tool_ids.uniq.length
    read_context = ReservationReadContext.new(shop: shop, member: member)
    validate_reservation_tool_ids!(shop, member, tool_ids, read_context: read_context) if tool_ids.present?
    view = SlackReservationModal.update(
      shop: shop,
      member: member,
      read_context: read_context,
      response_url: metadata["response_url"],
      slack_user_id: metadata["slack_user_id"],
      reservation_scope: scope,
      tool_ids: tool_ids,
      title: state.dig("title", "title", "value"),
      date: state.dig("date", "date", "selected_date"),
      start_time: state.dig("start_time", "start_time", "selected_time"),
      duration: state.dig("duration", "duration", "selected_option", "value")
    )
    ReservationTiming.measure("slack_views_update") do |metrics|
      metrics[:resource_count] = scope == "shop" ? 1 : tool_ids.uniq.length
      Service::SlackConnector.update_modal(
        payload.dig("view", "id"), view, hash: payload.dig("view", "hash")
      )
    end
    render json: {}
  rescue => error
    metrics[:outcome] = "error"
    Service::ErrorReporter.notify(error, context: { phase: "Slack reservation modal policy update" })
    render json: {}
  end

  def reservation_policy_action?(payload)
    payload.fetch("actions", []).any? do |action|
      action["action_id"].in?([
        SlackReservationModal::SCOPE_ACTION_ID,
        SlackReservationModal::TOOLS_ACTION_ID
      ])
    end
  end

  def selected_scope(state)
    state.dig("scope", SlackReservationModal::SCOPE_ACTION_ID, "selected_option", "value") ||
      state.dig("scope", "scope", "selected_option", "value")
  end

  def selected_tool_ids(state)
    selected = state.dig("tools", SlackReservationModal::TOOLS_ACTION_ID, "selected_options") ||
      state.dig("tools", "tools", "selected_options")
    Array(selected).map { |option| option["value"] }
  end

  def validate_reservation_tool_ids!(shop, member, tool_ids, read_context: nil)
    requested_ids = Array(tool_ids).map(&:to_s).uniq
    group_ids = requested_ids.grep(/\Agroup:/)
    if group_ids.any?
      expansion = ReservationGroupExpansion.call(shop_id: shop.id, reservation_scope: 'tools',
        tool_group_ids: group_ids.map { |id| id.delete_prefix('group:') }, tool_ids: [])
      children = Tool.where(:id.in => expansion[:tool_ids]).to_a
      if children.any? { |tool| tool.disabled? || tool.out_of_service? || (member.status == 'pending' && !tool.allow_pending) }
        raise Error::UnprocessableEntity.new('A group includes an unavailable tool')
      end
      requested_ids -= group_ids
    end
    candidates = read_context ? read_context.eligible_tools : Tool.where(
      shop_id: shop.id,
      :id.in => requested_ids,
      reservable: true,
      :disabled.ne => true
    ).to_a
    eligible = read_context ? candidates : ReservationPolicy.eligible_tools(
      shop: shop,
      member: member,
      tools: candidates
    )
    valid_ids = eligible.map { |tool| tool.id.to_s } & requested_ids
    return if valid_ids.sort == requested_ids.sort

    raise ::Error::UnprocessableEntity.new("One or more selected tools are no longer reservable in this shop")
  end

  def parse_reservation_duration(value)
    case value.to_s
    when /\Ahours:(\d+(?:\.[05])?)\z/
      hours = Regexp.last_match(1).to_f
      raise ::Error::UnprocessableEntity.new("Select a valid duration") unless hours.positive?

      { full_day: false, hours: hours }
    when /\Adays:(\d+)\z/
      days = Regexp.last_match(1).to_i
      raise ::Error::UnprocessableEntity.new("Select a valid duration") unless days.positive?

      { full_day: true, days: days }
    else
      raise ::Error::UnprocessableEntity.new("Select a valid duration")
    end
  end

  def reservation_error_field(message, state)
    text = message.to_s.downcase
    return "title" if text.match?(/title|name is required/)
    return "date" if text.match?(/date|future|horizon|booking window|same-day|same day/)
    return "start_time" if state.key?("start_time") && text.match?(/start time|advance notice|minute increment|30.minute/)
    return "duration" if state.key?("duration") && text.match?(/duration|end time|whole day|full.day/)
    if text.match?(/resource|shop|tool|checkout|prerequisite|reservable|selection/)
      return selected_scope(state) == "tools" && state.key?("tools") ? "tools" : "scope"
    end

    nil
  end

  def render_reservation_alert(payload, message)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    shop = Shop.find(metadata["shop_id"])
    member = Member.find(metadata["member_id"])
    tool_ids = selected_tool_ids(state)
    validate_reservation_tool_ids!(shop, member, tool_ids) if selected_scope(state) == "tools"
    view = SlackReservationModal.update(
      shop: shop,
      member: member,
      response_url: metadata["response_url"],
      slack_user_id: metadata["slack_user_id"],
      reservation_scope: selected_scope(state),
      tool_ids: tool_ids,
      title: state.dig("title", "title", "value"),
      date: state.dig("date", "date", "selected_date"),
      start_time: state.dig("start_time", "start_time", "selected_time"),
      duration: state.dig("duration", "duration", "selected_option", "value"),
      alert_message: message
    )
    render json: { response_action: "update", view: view }
  rescue => alert_error
    Service::ErrorReporter.notify(alert_error, context: { phase: "Slack reservation error rendering" })
    render json: {
      response_action: "errors",
      errors: { "scope" => "The reservation could not be created. Please use the Member Portal." }
    }
  end

  def close_reservation(payload)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    enqueue_reservation_outcome("Reservation cancelled without submission.", metadata, payload)
    render json: {}
  rescue JSON::ParserError => error
    Service::ErrorReporter.notify(error, context: { phase: "Slack reservation modal closure" })
    render json: {}
  end

  def reservation_outcome(reservation)
    case reservation.status
    when "pending"
      "Reservation *#{reservation.title}* was submitted and is *pending approval*."
    when "unpaid"
      "Reservation *#{reservation.title}* was created, but *payment is required* before it is approved."
    when "approved"
      "Reservation *#{reservation.title}* was created and is *approved*."
    else
      "Reservation *#{reservation.title}* was submitted and is *#{reservation.status}*."
    end
  end

  def enqueue_reservation_outcome(message, metadata, payload)
    slack_user_id = payload.dig("user", "id").presence || metadata["slack_user_id"]
    SlackReservationOutcomeJob.perform_later(message, metadata["response_url"], slack_user_id)
  rescue => error
    report_reservation_outcome_enqueue_failure(error, {
      phase: "Slack reservation outcome delivery",
      slack_user_id: slack_user_id
    })
  end

  def report_reservation_outcome_enqueue_failure(error, context)
    Service::ErrorReporter.notify(error, context: context)
  rescue => reporting_error
    Rails.logger.error(
      "[SlackReservationError] action=enqueue_outcome error=#{error.class} " \
      "reporting_error=#{reporting_error.class}"
    )
  end

  def create_checkout_request(payload)
    state = payload.dig("view", "state", "values") || {}
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    slack_user = SlackUser.find_by(slack_id: payload.dig("user", "id"))
    member = slack_user && Member.find_by(id: slack_user.member_id)
    return checkout_errors("tool" => "Link an active Member Portal account before requesting a checkout.") unless member

    shop = Shop.find_by(id: metadata["shop_id"])
    tool_id = state.dig("tool", "tool", "selected_option", "value")
    group_target = tool_id.to_s.start_with?('group:')
    tool = shop && (group_target ? ToolGroup.where(shop_id: shop.id, archived: false).find_by(id: tool_id.delete_prefix('group:')) : Tool.where(shop_id: shop.id, :disabled.ne => true).find_by(id: tool_id))
    return checkout_errors("tool" => "That shop or tool is no longer available.") unless tool
    error = group_target ? nil : ToolCheckoutRequestEligibility.new(member: member, tool: tool).error
    return checkout_errors("tool" => error) if error

    note = state.dig("note", "note", "value")
    return checkout_errors("note" => "Note is too long (maximum is 128 characters)") if note && (!note.is_a?(String) || note.length > 128)
    if group_target
      ToolGroupCheckout.request!(member: member, group: tool, note: note, defer_notifications: true)
    else
      CheckoutRequestCreation.create!(member_id: member.id, tool_id: tool.id, shop_id: shop.id, note: note, defer_notifications: true)
    end
    begin
      SlackCheckoutOutcomeJob.enqueue(checkout_confirmation(shop), metadata["response_url"], payload.dig("user", "id"))
    rescue => error
      SlackCheckoutOutcomeJob.report("enqueue", error_class: error.class.name)
    end
    render json: { response_action: "clear" }
  rescue JSON::ParserError
    checkout_errors("tool" => "The checkout form expired or is invalid. Please open it again.")
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "Slack checkout request submission" })
    checkout_errors("tool" => "The request could not be created. Please try again or use the Member Portal.")
  end

  def checkout_confirmation(shop)
    contacts = Member.tagged_resource_managers_for_shop(shop.id).filter_map do |manager|
      slack_user = SlackUser.find_by(member_id: manager.id)
      "<@#{slack_user.slack_id}>" if slack_user&.slack_id.present?
    end
    contact_text = contacts.present? ? contacts.join(", ") : "the shop's resource manager"
    "Your checkout request for *#{shop.name}* was received. Please be patient: checkouts are processed by unpaid volunteers. Interested in helping? Contact #{contact_text} about volunteering as an assistant checkout approver."
  end

  def checkout_errors(errors)
    render json: { response_action: "errors", errors: errors }
  end

  def verify_slack_signature
    secret = ENV["SLACK_SIGNING_SECRET"]
    if secret.blank?
      fix_payload = params[:payload].to_s.include?('fix_')
      return if Rails.env.development? && !fix_payload

      render json: { error: "Slack signing secret is not configured" },
        status: :forbidden
      return
    end

    timestamp = request.headers["X-Slack-Request-Timestamp"]
    signature = request.headers["X-Slack-Signature"]
    if (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: "Request too old" }, status: :forbidden and return
    end

    expected = "v0=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{request.raw_post}")}"
    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      render json: { error: "Invalid signature" }, status: :forbidden
    end
  end
end
