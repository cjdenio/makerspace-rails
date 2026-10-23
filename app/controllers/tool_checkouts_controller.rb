class ToolCheckoutsController < ApplicationController
  before_action :authenticate_member!

  def index
    # Always scoped to the current member — no elevation possible
    checkouts = ToolCheckout.where(member_id: current_member.id)

    # Optional active/revoked filter (mirrors admin controller behaviour)
    checkouts = checkouts.valid_at       if params[:active] == "true"
    checkouts = checkouts.where(:revoked_at.ne => nil) if params[:active] == "false"

    checkouts = checkouts.filtered_status(params[:status]) if params[:status].present?

    # Optional shop filter — join through tool
    if params[:shop_id].present?
      tool_ids = Tool.where(shop_id: params[:shop_id]).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    unless ActiveModel::Type::Boolean.new.cast(params[:include_hidden])
      visible_tool_ids = Tool.where(:disabled.ne => true).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => visible_tool_ids)
    end

    checkouts = checkouts.order_by(checked_out_at: :desc).to_a
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes, scope: current_member,
      checkout_context: CheckoutReadContext.for_checkouts(checkouts, current_member)
  end
end
