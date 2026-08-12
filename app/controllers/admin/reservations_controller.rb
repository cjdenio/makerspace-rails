class Admin::ReservationsController < ApplicationController
  around_action :handle_unexpected_reservation_errors
  before_action :authenticate_member!
  before_action :authorize_manager
  before_action :find_reservation, except: [:index, :create, :preview_create]
  before_action :authorize_reservation, except: [:index, :create, :preview_create]

  def index
    reservations = Reservation.all
    reservations = reservations.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    reservations = reservations.where(shop_id: params[:shop_id]) if params[:shop_id].present?
    if params[:status].present?
      statuses = params[:status] == "cancelled" ? %w[cancelled canceled] : [params[:status]]
      reservations = reservations.where(:status.in => statuses)
    end
    reservations = reservations.where(:end_at.gt => Time.current) if params[:future] == "true"

    render json: reservations.order_by(start_at: :asc),
      each_serializer: ReservationSerializer,
      adapter: :attributes,
      scope: current_member
  end

  def create
    member = delegated_member
    authorize_delegated_shop!
    reservation = ReservationService.create!(
      member: member,
      attributes: reservation_params,
      source: "portal"
    )
    audit_reservation_action("reservation_created_on_behalf", reservation, subject: member)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes,
      scope: current_member, status: :created
  end

  def preview_create
    member = delegated_member
    authorize_delegated_shop!
    render json: ReservationService.preview(
      member: member,
      attributes: reservation_params
    )
  end

  def update
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
      raise ::Error::Forbidden.new("You are not authorized to move this reservation to the selected shop")
    end
    reservation = ReservationService.update!(reservation: @reservation, attributes: reservation_params)
    audit_reservation_action("reservation_updated_by_manager", reservation)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def preview
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
      raise ::Error::Forbidden.new("You are not authorized to manage reservations for the selected shop")
    end
    render json: ReservationService.preview(
      member: @reservation.member,
      attributes: reservation_params,
      reservation: @reservation
    )
  end

  def destroy
    reservation = ReservationService.cancel!(reservation: @reservation, actor: current_member)
    audit_reservation_action("reservation_cancelled_by_manager", reservation)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def approve
    reservation = ReservationService.approve!(
      reservation: @reservation,
      actor: current_member,
      note: decision_params[:decision_note]
    )
    audit_reservation_action("reservation_approved", reservation)
    ReservationDecisionNotificationJob.perform_later(reservation.id.to_s)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def deny
    reservation = ReservationService.deny!(
      reservation: @reservation,
      actor: current_member,
      note: decision_params[:decision_note]
    )
    audit_reservation_action("reservation_denied", reservation)
    ReservationDecisionNotificationJob.perform_later(reservation.id.to_s)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  private

  def authorize_manager
    unless is_admin? || is_board_member? || (is_resource_manager? && managed_shop_ids.present?)
      raise ::Error::Forbidden.new(
        "You are not authorized to manage reservations. Checkout-approver access does not grant reservation-management access"
      )
    end
  end

  def authorize_reservation
    unless is_admin? || is_board_member? || manages_shop?(@reservation.shop_id)
      raise ::Error::Forbidden.new("You are not authorized to manage reservations for this shop")
    end
  end

  def find_reservation
    @reservation = Reservation.find(params[:id])
  end

  def delegated_member
    @delegated_member ||= begin
      member = Member.find(params.require(:member_id))
      unless member.status == 'pending' || member.active_unexpired?
        raise ::Error::UnprocessableEntity.new(
          "Reservations may only be created on behalf of an active, unexpired member"
        )
      end
      member
    end
  end

  def authorize_delegated_shop!
    unless is_board_member? || current_member.active_unexpired?
      raise ::Error::Forbidden.new(
        "Your membership must be active and unexpired to create a reservation for another member"
      )
    end

    shop_id = reservation_params[:shop_id]
    unless is_admin? || is_board_member? || manages_shop?(shop_id)
      raise ::Error::Forbidden.new(
        "You are not authorized to create reservations for members in the selected shop"
      )
    end
  end

  def reservation_params
    params.permit(:title, :shop_id, :reservation_scope, :start_at, :end_at, tool_ids: [])
  end

  def decision_params
    params.permit(:decision_note)
  end

  def audit_reservation_action(event_type, reservation, subject: reservation.member)
    ::Service::AuditLogger.log(
      log_type: "portal",
      event_type: event_type,
      resource_type: "Reservation",
      resource_id: reservation.id,
      actor: current_member,
      subject: subject,
      after_snapshot: reservation.attributes
    )
  end

  def handle_unexpected_reservation_error(error)
    Rails.logger.error(
      "[ReservationManagerError] action=#{action_name} member_id=#{current_member&.id} " \
      "error=#{error.class}: #{error.message}\n#{Array(error.backtrace).first(10).join("\n")}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      status: 500,
      error: "internal_server_error",
      message: "The reservation could not be processed. Please try again or contact an administrator " \
        "with request ID #{Current.request_id}."
    }, status: :internal_server_error
  end

  def handle_unexpected_reservation_errors
    yield
  rescue ::Error::CustomError, ::Mongoid::Errors::MongoidError,
         ::ActionController::ParameterMissing, ::ActionController::InvalidAuthenticityToken
    raise
  rescue => error
    handle_unexpected_reservation_error(error)
  end
end
