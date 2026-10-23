class RentalSpotsController < AuthenticationController
  include FastQuery::MongoidQuery

  # Unauthenticated deep-link info — used by QR/deep-link landing pages so a
  # member who isn't logged in yet can see basic spot info before signing in.
  skip_before_action :authenticate_member!, :authenticated?, only: [:public_show]

  def index
    spots = RentalSpot.where(active: true)
    spots = spots.where(rental_type_id: params[:rental_type_id]) if params[:rental_type_id].present?

    if params[:available] == "true"
      available = spots.select(&:available?)
      return render json: available, each_serializer: RentalSpotSerializer, adapter: :attributes
    end

    render_with_total_items(
      query_resource(spots),
      { each_serializer: RentalSpotSerializer, adapter: :attributes }
    )
  end

  def show
    @spot = find_rental_spot(params[:id])
    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  # GET /api/rental_spots/:id/public — unauthenticated.
  # Used for deep-link/QR landing pages. Returns only non-sensitive,
  # already-public-facing info (the same a member sees in the catalog).
  def public_show
    @spot = find_rental_spot(params[:id])
    render json: @spot, serializer: RentalSpotPublicSerializer, adapter: :attributes
  end

  private

  # Deep links may reference a spot by its Mongo id OR by its human-readable
  # `number` (e.g. "LR-Tote-1") so admins can build/print/QR a link using the
  # number shown in the catalog without looking up the underlying id.
  def find_rental_spot(identifier)
    spot = BSON::ObjectId.legal?(identifier) ? RentalSpot.where(id: identifier).first : nil
    spot ||= RentalSpot.find_by(number: identifier)
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: identifier }) if spot.nil?
    spot
  end
end
