class ToolsController < AuthenticationController
  prepend_before_action { response.set_header("Cache-Control", "private, no-store") }

  def index
    unless current_member.status == 'pending' || current_member.active_unexpired?
      raise ::Error::Forbidden.new(
        "Your membership must first be activated and you must complete your Orientation checkout before requesting additional Safety Checkouts"
      )
    end

    excluded_tool_ids = ToolCheckout.where(member_id: current_member.id).pluck(:tool_id).map(&:to_s)
    tools = Tool.where(:disabled.ne => true, :open.ne => true, :shop_id.in => Shop.where(:disabled.ne => true).pluck(:id)).where(:id.nin => excluded_tool_ids)
    tools = tools.where(allow_pending: true) if current_member.status == 'pending'
    tools = tools.where(shop_id: params[:shop_id]) if params[:shop_id].present?

    render json: tools.order_by(name: :asc),
      each_serializer: ToolCatalogSerializer,
      adapter: :attributes,
      scope: current_member
  end
end
