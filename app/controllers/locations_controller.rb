class LocationsController < ApplicationController
  before_action :authenticate_member!

  # Read-only, any signed-in member -- unlike Admin::LocationsController#index
  # (which scopes a non-admin/board/shop-manager viewer down to only shops
  # they manage), a location's map position isn't sensitive, and the member
  # shop-map view needs to show every shop's area regardless of who's
  # looking. Mirrors the plain ShopsController/ToolsController vs their
  # Admin:: counterparts.
  def index
    locations = params[:shop_ids] ? Location.where(:shop_id.in => Array(params[:shop_ids])) : Location.all
    render json: locations.includes(:shop).to_a, each_serializer: LocationSerializer, adapter: :attributes
  end
end
