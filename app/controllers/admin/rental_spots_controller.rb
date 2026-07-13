class Admin::RentalSpotsController < AdminController
  include FastQuery::MongoidQuery
  before_action :set_spot, only: [:update, :destroy]

  def index
    spots = RentalSpot.all
    spots = spots.where(rental_type_id: params[:rental_type_id]) if params[:rental_type_id].present?
    spots = spots.where(active: params[:active] == "true") if params[:active].present?
    render_with_total_items(
      query_resource(spots),
      { each_serializer: RentalSpotSerializer, adapter: :attributes }
    )
  end

  def create
    @spot = RentalSpot.new(spot_params)
    @spot.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'rental_spot_created',
      resource_type:  'RentalSpot',
      resource_id:    @spot.id,
      actor:          current_member,
      after_snapshot: @spot.attributes
    )

    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  def update
    before = @spot.attributes.dup
    @spot.update_attributes!(spot_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'rental_spot_updated',
      resource_type:   'RentalSpot',
      resource_id:     @spot.id,
      actor:           current_member,
      field_changes:   @spot.previous_changes,
      before_snapshot: before,
      after_snapshot:  @spot.attributes
    )

    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  def destroy
    before = @spot.attributes.dup
    @spot.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'rental_spot_deleted',
      resource_type:   'RentalSpot',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def set_spot
    @spot = RentalSpot.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:id] }) if @spot.nil?
  end

  def spot_params
    params.require(:number)
    params.require(:rental_type_id)
    params.require(:location)
    params.permit(:number, :location, :description, :rental_type_id,
                  :requires_approval, :active, :parent_number, :notes)
  end
end
