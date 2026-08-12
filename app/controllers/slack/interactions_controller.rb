class Slack::InteractionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    payload = JSON.parse(params[:payload].to_s)
    return render json: {} unless payload["type"] == "view_submission" &&
      payload.dig("view", "callback_id") == "reservation_submit"

    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    member = Member.find(metadata["member_id"])
    date = state.dig("date", "date", "selected_date")
    start_text = state.dig("start_time", "start_time", "selected_time")
    end_text = state.dig("end_time", "end_time", "selected_time")
    start_at = ReservationService::ZONE.parse("#{date} #{start_text}")
    end_at = ReservationService::ZONE.parse("#{date} #{end_text}")
    end_at += 1.day if end_at <= start_at

    reservation = ReservationService.create!(
      member: member,
      source: "slack",
      attributes: {
        title: state.dig("title", "title", "value"),
        shop_id: metadata["shop_id"],
        reservation_scope: state.dig("scope", "scope", "selected_option", "value"),
        tool_ids: Array(state.dig("tools", "tools", "selected_options")).map { |option| option["value"] },
        start_at: start_at,
        end_at: end_at
      }
    )

    message = "Reservation *#{reservation.title}* was submitted and is *#{reservation.status}*."
    if reservation.status == "pending" && reservation.effective_approval_details.present?
      reasons = reservation.effective_approval_details.map { |detail| "• #{detail['message']}" }
      message += "\nApproval required because:\n#{reasons.join("\n")}"
    end
    Service::SlackConnector.send_slack_message(message, payload.dig("user", "id"))
    render json: { response_action: "clear" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=create member_id=#{member&.id} reason=#{error.message}"
    )
    render json: {
      response_action: "errors",
      errors: { "end_time" => error.message.to_s.first(150) }
    }
  rescue => error
    Rails.logger.error(
      "[SlackReservationError] action=create member_id=#{member&.id} " \
      "error=#{error.class}: #{error.message}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      response_action: "errors",
      errors: {
        "end_time" => "The reservation could not be created. Please verify the times and use the Member Portal if the problem continues."
      }
    }
  end

  private

  def verify_slack_signature
    secret = ENV["SLACK_SIGNING_SECRET"]
    if secret.blank?
      return if Rails.env.development?

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
