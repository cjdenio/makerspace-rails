class RentalTypesController < AuthenticationController
  def index
    types = RentalType.where(active: true)
    render json: types, each_serializer: RentalTypeSerializer, adapter: :attributes
  end
end
