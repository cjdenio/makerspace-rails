class Admin::ToolCheckoutsController < ApplicationController
  include Service::SlackConnector
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :find_checkout, only: [:update, :destroy]
  before_action :authorize_approver, only: [:create, :destroy]

  def index
    checkouts = ToolCheckout.all

    # Filter by member, tool, shop, active status
    checkouts = checkouts.where(member_id: params[:member_id]) if params[:member_id].present?
    checkouts = checkouts.where(tool_id: params[:tool_id]) if params[:tool_id].present?
    checkouts = checkouts.where(revoked_at: nil) if params[:active] == "true"
    checkouts = checkouts.where(:revoked_at.ne => nil) if params[:active] == "false"

    # Filter by shop — join through tool
    if params[:shop_id].present?
      tool_ids = Tool.where(shop_id: params[:shop_id]).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    unless can_view_disabled_tools?
      approver_shop_ids = CheckoutApprover.shops_for_member(current_member.id).map(&:id)
      tool_ids = Tool.where(:shop_id.in => approver_shop_ids, :disabled.ne => true).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    checkouts = checkouts.order_by(checked_out_at: :desc)
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  def create
    member = Member.find(checkout_params[:member_id])
    tool   = Tool.find(checkout_params[:tool_id])
    raise ::Error::Forbidden.new if tool.disabled? && !can_view_disabled_tools?

    # Warn if prerequisites not met — but do not block
    unmet = unmet_prerequisites(member, tool)

    # Prevent duplicate active checkout
    existing = ToolCheckout.find_by(member_id: member.id, tool_id: tool.id, revoked_at: nil)
    if existing
      render json: { error: "Member is already checked out on this tool" }, status: :unprocessable_content and return
    end

    checkout = ToolCheckout.new(
      member_id:      member.id,
      tool_id:        tool.id,
      approved_by_id: current_member.id,
      signed_off_via: "portal",
      checked_out_at: Time.now
    )
    checkout.save!
    checkout.send_checkout_slack_notification
    checkout.announce_checkout_success

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'tool_checkout_created',
      resource_type:  'ToolCheckout',
      resource_id:    checkout.id,
      actor:          current_member,
      subject:        member,
      after_snapshot: { member_id: member.id.to_s, tool_id: tool.id.to_s,
                        tool_name: tool.name, approved_by: current_member.fullname },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: checkout.as_json(
      serializer: ToolCheckoutSerializer,
      adapter: :attributes
    ).merge(unmet_prerequisites: unmet.map(&:name)), adapter: :attributes
  end

  def update
    # Only allow updating revocation fields
    if update_params[:revoked_at] || update_params[:revocation_reason]
      @checkout.update_attributes!(update_params)
      @checkout.send_revocation_slack_notification if @checkout.revoked_at.present?
    end
    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  def destroy
    reason = params[:revocation_reason].presence
    raise ::Error::UnprocessableEntity.new("Revocation reason is required") unless reason

    @checkout.update_attributes!(
      revoked_at: Time.now,
      revocation_reason: reason
    )
    @checkout.send_revocation_slack_notification
    @checkout.remove_member_from_users_channel

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'tool_checkout_revoked',
      resource_type:  'ToolCheckout',
      resource_id:    @checkout.id,
      actor:          current_member,
      subject:        @checkout.member,
      after_snapshot: { tool_id: @checkout.tool_id.to_s, revocation_reason: reason },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  private

  def checkout_params
    params.require([:member_id, :tool_id])
    params.permit(:member_id, :tool_id)
  end

  def update_params
    params.permit(:revoked_at, :revocation_reason)
  end

  def find_checkout
    @checkout = ToolCheckout.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(ToolCheckout, { id: params[:id] }) if @checkout.nil?
  end

  def authorize_index
    raise ::Error::Forbidden.new unless can_view_disabled_tools? || is_valid_checkout_approver?
  end

  # Admins can approve anything. RMs and checkout approvers are shop-scoped.
  def authorize_approver
    return if is_admin? || is_board_member?
    tool = @checkout.try(:tool) || Tool.find(params[:tool_id])

    if is_resource_manager?
      # RMs have access to all tools — no shop restriction
      return
    end

    return render json: { error: "You are not authorized to approve checkouts for disabled tools" }, status: 403 if tool.disabled?
    shop_id = tool.try(:shop_id)

    unless current_member.valid_for_checkout_request?
      render json: { error: "You must be an active, unexpired member with a contract on file to approve checkouts" }, status: 403 and return
    end

    approver = CheckoutApprover.find_by(member_id: current_member.id)
    unless approver && approver.can_approve_for_shop?(shop_id)
      render json: { error: "You are not authorized to approve checkouts for this shop" }, status: 403
    end
  end

  def unmet_prerequisites(member, tool)
    return [] if tool.prerequisite_ids.blank?
    checked_out_tool_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    tool.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_tool_ids.include?(pid) }.map do |pid|
      Tool.find(pid) rescue nil
    end.compact
  end
end
