class Admin::ReservationBlackoutsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_manager
  before_action :find_blackout, only: [:update, :destroy]
  before_action :authorize_existing_shop, only: [:update, :destroy]

  def index
    blackouts = ReservationBlackout.all
    blackouts = blackouts.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    if params[:shop_id].present?
      authorize_shop!(params[:shop_id])
      blackouts = blackouts.where(shop_id: params[:shop_id])
    end

    render json: blackouts.order_by(shop_id: :asc, start_time: :asc),
      each_serializer: ReservationBlackoutSerializer,
      adapter: :attributes
  end

  def create
    authorize_shop!(blackout_params[:shop_id])
    blackout = ReservationBlackout.create!(
      blackout_params.merge(created_by_id: current_member.id)
    )
    audit("reservation_blackout_created", blackout, after_snapshot: blackout.attributes)
    enqueue_canvas_sync(blackout.shop_id)

    render json: blackout, serializer: ReservationBlackoutSerializer,
      adapter: :attributes, status: :created
  end

  def update
    target_shop_id = blackout_params[:shop_id].presence || @blackout.shop_id
    authorize_shop!(target_shop_id)
    before = @blackout.attributes.dup
    old_shop_id = @blackout.shop_id
    @blackout.update!(blackout_params)
    audit(
      "reservation_blackout_updated",
      @blackout,
      before_snapshot: before,
      after_snapshot: @blackout.attributes,
      field_changes: @blackout.previous_changes
    )
    enqueue_canvas_sync(old_shop_id)
    enqueue_canvas_sync(@blackout.shop_id) if @blackout.shop_id.to_s != old_shop_id.to_s

    render json: @blackout, serializer: ReservationBlackoutSerializer, adapter: :attributes
  end

  def destroy
    before = @blackout.attributes.dup
    shop_id = @blackout.shop_id
    blackout_id = @blackout.id
    @blackout.destroy
    ::Service::AuditLogger.log(
      log_type: "portal",
      event_type: "reservation_blackout_deleted",
      resource_type: "ReservationBlackout",
      resource_id: blackout_id,
      actor: current_member,
      before_snapshot: before,
      after_snapshot: {}
    )
    enqueue_canvas_sync(shop_id)
    head :no_content
  end

  private

  def authorize_manager
    return if is_admin? || is_board_member?
    return if is_resource_manager? && managed_shop_ids.present?

    raise ::Error::Forbidden.new("You are not authorized to manage reservation blackouts")
  end

  def authorize_existing_shop
    authorize_shop!(@blackout.shop_id)
  end

  def authorize_shop!(shop_id)
    return if is_admin? || is_board_member? || manages_shop?(shop_id)

    raise ::Error::Forbidden.new("You are not authorized to manage blackouts for this shop")
  end

  def find_blackout
    @blackout = ReservationBlackout.find(params[:id])
  end

  def blackout_params
    params.permit(
      :title, :shop_id, :recurrence, :weekday,
      :start_time, :end_time, :start_date, :end_date
    )
  end

  def audit(event_type, blackout, **options)
    ::Service::AuditLogger.log(
      log_type: "portal",
      event_type: event_type,
      resource_type: "ReservationBlackout",
      resource_id: blackout.id,
      actor: current_member,
      **options
    )
  end

  def enqueue_canvas_sync(shop_id)
    today = Time.current.in_time_zone(ReservationService::ZONE).to_date
    ReservationSlackCanvasSyncJob.perform_later(
      shop_id.to_s,
      [today.iso8601, (today + 1.day).iso8601]
    )
  end
end
