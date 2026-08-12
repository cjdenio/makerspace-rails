class ReservationAgendasController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_after_action :send_messages
  before_action :check_token
  before_action :find_shop_and_tool

  def index
    now = Time.current
    window_end = now + 24.hours
    reservations = Reservation.blocking.where(
      shop_id: @shop.id,
      :start_at.lt => window_end,
      :end_at.gt => now
    )
    if @tool
      reservations = reservations.any_of(
        { reservation_scope: "shop" },
        { reservation_scope: "tools", tool_ids: @tool.id.to_s }
      )
    end
    reservations = reservations.order_by(start_at: :asc).to_a
    @agenda_tools = Tool.where(
      shop_id: @shop.id,
      reservable: true,
      :disabled.ne => true
    ).order_by(name: :asc).to_a

    rows = reservations.map { |reservation| agenda_row(reservation, now) }
    next_reservation = @tool &&
      reservations.select { |reservation| reservation.start_at > now }.min_by(&:start_at)
    agenda = {
      shopName: @shop.name,
      toolName: @tool&.name,
      generatedAt: now.iso8601,
      windowStart: now.iso8601,
      windowEnd: window_end.iso8601,
      upNext: next_reservation ? up_next_row(next_reservation) : nil,
      reservations: rows
    }

    if request.format.json?
      render json: agenda
    else
      @agenda = agenda
      render :index, layout: false
    end
  end

  private

  def check_token
    expected = SystemConfig.get("reservation_token").presence ||
      ENV["RESERVATION_TOKEN"].to_s.presence
    return if expected.blank?

    provided = params[:token].to_s
    return if provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    render_agenda_error("Access denied.", :forbidden)
  end

  def find_shop_and_tool
    if params[:shop].blank?
      render_agenda_error("Shop name is required.", :bad_request)
      return
    end

    @shop = Shop.where(
      name: /\A#{Regexp.escape(params[:shop].to_s.strip)}\z/i,
      :disabled.ne => true
    ).first
    unless @shop
      render_agenda_error("Shop was not found.", :not_found)
      return
    end
    return if params[:tool].blank?

    @tool = Tool.where(
      shop_id: @shop.id,
      name: /\A#{Regexp.escape(params[:tool].to_s.strip)}\z/i,
      :disabled.ne => true
    ).first
    render_agenda_error("Tool was not found in #{@shop.name}.", :not_found) unless @tool
  end

  def agenda_row(reservation, now)
    slack_user = reservation.member&.slack_user
    {
      title: reservation.title,
      memberName: reservation.member&.fullname,
      slackUsername: slack_user&.name,
      startAt: reservation.start_at.iso8601,
      endAt: reservation.end_at.iso8601,
      status: reservation.status,
      reservationScope: reservation.reservation_scope,
      toolNames: reservation.tools.map(&:name),
      inProgress: reservation.start_at <= now && reservation.end_at > now
    }
  end

  def up_next_row(reservation)
    {
      memberName: reservation.member&.fullname,
      slackUsername: reservation.member&.slack_user&.name,
      startAt: reservation.start_at.iso8601
    }
  end

  def render_agenda_error(message, status)
    if request.format.json?
      render json: { error: message }, status: status
    else
      render plain: message, status: status
    end
  end
end
