class ReservationCatalogController < ApplicationController
  before_action :authenticate_member!
  before_action :require_active_member

  def index
    enabled_shops = Shop.where(:disabled.ne => true)
    tools = Tool.where(
      :disabled.ne => true,
      reservable: true,
      :shop_id.in => enabled_shops.pluck(:id)
    ).order_by(name: :asc)
    tools = tools.where(allow_pending: true) if current_member.status == 'pending'
    shop_ids = tools.pluck(:shop_id)
    shops = if current_member.status == 'pending'
      enabled_shops.where(:id.in => shop_ids)
    else
      enabled_shops.any_of(
        { reservable: true },
        { :id.in => shop_ids }
      )
    end.order_by(name: :asc)

    render json: {
      shops: ActiveModelSerializers::SerializableResource.new(
        shops, each_serializer: ShopSerializer, adapter: :attributes, scope: current_member
      ),
      tools: ActiveModelSerializers::SerializableResource.new(
        tools, each_serializer: ToolSerializer, adapter: :attributes
      )
    }
  end

  private

  def require_active_member
    return if current_member.role.in?(%w[admin board_member])
    return if current_member.role == "resource_manager" &&
      current_member.resource_manager_shop_ids.present?
    return if current_member.status == 'pending'
    return if current_member.active_unexpired?

    raise ::Error::Forbidden.new("Active membership is required")
  end
end
