class Admin::ToolsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :authorize_manage, only: [:create, :update, :destroy]
  before_action :find_tool, only: [:update, :destroy]

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    unless can_view_disabled_tools?
      approver_shop_ids = CheckoutApprover.shops_for_member(current_member.id).map(&:id)
      tools = tools.where(:shop_id.in => approver_shop_ids, :disabled.ne => true)
    end
    tools = tools.order_by(name: :asc)
    render json: tools, each_serializer: ToolSerializer, adapter: :attributes
  end

  def create
    tool = Tool.new(tool_params)
    tool.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'tool_created',
      resource_type:  'Tool',
      resource_id:    tool.id,
      actor:          current_member,
      after_snapshot: tool.attributes
    )

    render json: tool, serializer: ToolSerializer, adapter: :attributes
  end

  def update
    before = @tool.attributes.dup
    @tool.update_attributes!(tool_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_updated',
      resource_type:   'Tool',
      resource_id:     @tool.id,
      actor:           current_member,
      field_changes:   @tool.previous_changes,
      before_snapshot: before,
      after_snapshot:  @tool.attributes
    )

    render json: @tool, serializer: ToolSerializer, adapter: :attributes
  end

  def destroy
    before = @tool.attributes.dup
    @tool.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_deleted',
      resource_type:   'Tool',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def tool_params
    params.permit(:name, :description, :shop_id, :disabled, :announce,
      :announce_channel, :users_channel, prerequisite_ids: [])
  end

  def find_tool
    @tool = Tool.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Tool, { id: params[:id] }) if @tool.nil?
  end

  def authorize_index
    unless can_view_disabled_tools? || is_valid_checkout_approver?
      raise ::Error::Forbidden.new("User is not privileged or a checkout approver")
    end
  end

  def authorize_manage
    raise ::Error::Forbidden.new("User is not privileged") unless can_view_disabled_tools?
  end
end
