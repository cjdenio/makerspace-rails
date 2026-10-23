class Admin::ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_view

  def index
    requests = CheckoutInteractionQuery.new(member: current_member).open_requests(for_approval: true)
    if params[:include_groups] == 'true'
      group_requests = CheckoutInteractionQuery.new(member: current_member).visible_group_requests
      requests = requests.to_a + group_requests.select { |request| ToolGroupCheckout.authorized?(current_member, request.tool_group) }
    end

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  # POST /api/admin/tool_checkout_requests/:id/decline  { reason: "..." }
  def decline
    request = ToolCheckoutRequest.find(params[:id])
    raise ::Error::NotFound.new unless request

    CheckoutRequestDecision.decline!(request: request, actor: current_member, reason: params[:reason])
    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  private

  def authorize_view
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? ||
      managed_shop_ids.present? || is_valid_checkout_approver?
  end
end
