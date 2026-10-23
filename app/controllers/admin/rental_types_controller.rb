class Admin::RentalTypesController < AdminController
  include FastQuery::MongoidQuery
  before_action :set_rental_type, only: [:update, :destroy]

  def index
    types = RentalType.all
    render_with_total_items(
      query_resource(types),
      { each_serializer: RentalTypeSerializer, adapter: :attributes }
    )
  end

  def create
    @rental_type = RentalType.new(rental_type_params)
    @rental_type.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'rental_type_created',
      resource_type:  'RentalType',
      resource_id:    @rental_type.id,
      actor:          current_member,
      after_snapshot: @rental_type.attributes
    )

    render json: @rental_type, serializer: RentalTypeSerializer, adapter: :attributes
  end

  def update
    before = @rental_type.attributes.dup
    @rental_type.update_attributes!(rental_type_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'rental_type_updated',
      resource_type:   'RentalType',
      resource_id:     @rental_type.id,
      actor:           current_member,
      field_changes:   @rental_type.previous_changes,
      before_snapshot: before,
      after_snapshot:  @rental_type.attributes
    )

    render json: @rental_type, serializer: RentalTypeSerializer, adapter: :attributes
  end

  def destroy
    before = @rental_type.attributes.dup
    @rental_type.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'rental_type_deleted',
      resource_type:   'RentalType',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def set_rental_type
    @rental_type = RentalType.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalType, { id: params[:id] }) if @rental_type.nil?
  end

  def rental_type_params
    params.require(:display_name)
    params.permit(:display_name, :active, :invoice_option_id)
  end
end
