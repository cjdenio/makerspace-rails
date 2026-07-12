class ToolsController < AuthenticationController
  def index
    raise ::Error::Forbidden.new unless current_member.active_unexpired?

    excluded_tool_ids = ToolCheckout.where(member_id: current_member.id).pluck(:tool_id).map(&:to_s)
    tools = Tool.where(:disabled.ne => true).where(:id.nin => excluded_tool_ids)

    render json: tools.order_by(name: :asc),
      each_serializer: ToolCatalogSerializer,
      adapter: :attributes,
      scope: current_member
  end
end
