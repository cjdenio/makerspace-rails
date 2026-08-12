class Admin::ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_view

  def index
    requests = ToolCheckoutRequest.where(status: "open")

    if is_admin? || is_board_member?
      requests = requests.where(:tool_id.in => Tool.all.pluck(:id))
    else
      managed_tool_ids = Tool.where(:shop_id.in => managed_shop_ids).pluck(:id).map(&:to_s)
      ordinary_tool_ids = CheckoutApprover.allowed_tool_ids_for_member(current_member.id)
      ordinary_tool_ids &= Tool.where(:disabled.ne => true).pluck(:id).map(&:to_s)
      tool_ids = (managed_tool_ids + ordinary_tool_ids).uniq
      valid_member_ids = Member.all.select do |member|
        member.status == 'pending' || member.active_unexpired?
      end.map(&:id)
      requests = requests.where(:tool_id.in => tool_ids, :member_id.in => valid_member_ids)
    end

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  private

  def authorize_view
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? ||
      managed_shop_ids.present? || is_valid_checkout_approver?
  end
end
