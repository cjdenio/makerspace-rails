class Admin::VolunteerEventsController < AdminOrRmController
  before_action :find_event, only: [:show, :close, :add_attendee, :remove_attendee, :destroy]

  # GET /api/admin/volunteer_events
  def index
    events = VolunteerEvent.all.order_by(created_at: :desc)
    events = events.where(status: params[:status]) if params[:status].present?
    render json: events, each_serializer: VolunteerEventSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_events
  def create
    event = VolunteerEvent.new(event_params.merge(created_by_id: current_member.id))
    event.save!
    render json: event, serializer: VolunteerEventSerializer, adapter: :attributes
  end

  # GET /api/admin/volunteer_events/:id
  def show
    render json: @event, serializer: VolunteerEventSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_events/:id/close
  def close
    if @event.status != 'open'
      render json: { error: 'Event is already closed' }, status: :forbidden and return
    end
    @event.close!(current_member)
    render json: @event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to close this event' }, status: :forbidden
  end

  # POST /api/admin/volunteer_events/:id/add_attendee
  def add_attendee
    member = Member.find(params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:member_id] }) if member.nil?

    if @event.status != 'open'
      render json: { error: 'Event is not open' }, status: :forbidden and return
    end

    if @event.attendee_ids.include?(member.id)
      render json: { error: "#{member.fullname} is already checked in" }, status: :forbidden and return
    end

    @event.add_attendee!(member, current_member)
    render json: @event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to add attendee' }, status: :forbidden
  end

  # DELETE /api/admin/volunteer_events/:id/remove_attendee
  # Removes a member's check-in. Blocked on closed events.
  # DMs the member notifying them of the removal.
  def remove_attendee
    member = Member.find(params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:member_id] }) if member.nil?

    if @event.status != 'open'
      render json: { error: 'Event is not open — cannot remove attendees from a closed event' }, status: :forbidden and return
    end

    unless @event.attendee_ids.include?(member.id)
      render json: { error: "#{member.fullname} is not checked in to this event" }, status: :unprocessable_content and return
    end

    @event.remove_attendee!(member, current_member)
    render json: @event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to remove attendee' }, status: :unprocessable_content
  end

  # DELETE /api/admin/volunteer_events/:id
  def destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
    @event.destroy
    render json: {}, status: :no_content
  end

  private

  def find_event
    @event = VolunteerEvent.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerEvent, { id: params[:id] }) if @event.nil?
  end

  def event_params
    params.permit(:title, :description, :credit_value, :event_date)
  end
end
