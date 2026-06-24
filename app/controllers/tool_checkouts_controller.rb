class ToolCheckoutsController < ApplicationController
  before_action :authenticate_member!

  def index
    # Always scoped to the current member — no elevation possible
    checkouts = ToolCheckout.where(member_id: current_member.id)

    # Optional active/revoked filter (mirrors admin controller behaviour)
    checkouts = checkouts.where(revoked_at: nil)       if params[:active] == "true"
    checkouts = checkouts.where(:revoked_at.ne => nil) if params[:active] == "false"

    # Optional shop filter — join through tool
    if params[:shop_id].present?
      tool_ids = Tool.where(shop_id: params[:shop_id]).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    checkouts = checkouts.order_by(checked_out_at: :desc)
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes
  end
end
