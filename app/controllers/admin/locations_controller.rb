class Admin::LocationsController < ApplicationController
  before_action :authenticate_member!
  before_action :find_location, only: [:update, :destroy]
  before_action :authorize_create, only: [:create]
  before_action :authorize_manage, only: [:update, :destroy]

  def index
    locations = if params[:shop_ids]
      Location.where(:shop_id.in => Array(params[:shop_ids]))
    elsif params[:shop_id]
      Location.where(shop_id: params[:shop_id])
    else
      Location.all
    end
    locations = locations.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    render json: locations.includes(:shop).to_a, each_serializer: LocationSerializer, adapter: :attributes
  end

  def create
    location = Location.new(location_params)
    location.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'location_created',
      resource_type:  'Location',
      resource_id:    location.id,
      actor:          current_member,
      after_snapshot: location.attributes
    )

    render json: location, serializer: LocationSerializer, adapter: :attributes
  end

  def update
    before = @location.attributes.dup
    @location.update_attributes!(location_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'location_updated',
      resource_type:   'Location',
      resource_id:     @location.id,
      actor:           current_member,
      field_changes:   @location.previous_changes,
      before_snapshot: before,
      after_snapshot:  @location.attributes
    )

    render json: @location, serializer: LocationSerializer, adapter: :attributes
  end

  def destroy
    before = @location.attributes.dup
    # Deleting a location cascades to everything nested under it, at any
    # depth -- a child, that child's own children, and so on. Without this,
    # descendants are left behind with a parent_id pointing at a now-deleted
    # document (invisible in the tree, unreachable except by direct id).
    descendants = @location.descendants
    affected = [@location] + descendants
    # A tool placed at any of these locations still points at its id by
    # location_id alone (no DB-level foreign key) -- leaving that dangling
    # at a now-deleted id is what the "place a specific tool here" picker
    # reads as "already placed somewhere," refusing to offer the tool again.
    affected_tool_names = Tool.where(:location_id.in => affected.map(&:id)).pluck(:name)
    Tool.where(:location_id.in => affected.map(&:id)).update_all(location_id: nil)
    descendants.each(&:destroy)
    @location.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'location_deleted',
      resource_type:   'Location',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before.merge(
        'deleted_descendant_ids'   => descendants.map { |d| d.id.to_s },
        'unassigned_tool_names'    => affected_tool_names
      ),
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def location_params
    params.permit(:name, :kind, :parent_id, :shop_id, :svg_element_id, :x_pct, :y_pct,
                   :floor_name, :icon, shape_points: [:x, :y])
  end

  def find_location
    @location = Location.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Location, { id: params[:id] }) if @location.nil?
  end

  def authorize_create
    shop = Shop.find(location_params[:shop_id])
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(shop)
  end

  def authorize_manage
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(@location.shop_id)

    target_shop_id = location_params[:shop_id].presence
    if target_shop_id && !can_manage_shop?(target_shop_id)
      raise ::Error::Forbidden.new("User cannot move this location to that shop")
    end
  end
end
