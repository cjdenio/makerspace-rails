class ToolGroupsController < ApplicationController
  before_action :authenticate_member!
  before_action :find_group, except: [:index, :create]

  def index
    groups = ToolGroup.where(archived: false, :shop_id.in => Shop.where(:disabled.ne => true).pluck(:id))
    groups = groups.where(shop_id: params[:shop_id]) if params[:shop_id].present?
    groups = groups.order_by(name: :asc).collation(locale: 'en', strength: 2).to_a
    groups.select! { |group| ToolGroup.manageable_by?(current_member, group.shop_id) || group.included_tools.none?(&:disabled?) }
    render json: groups, each_serializer: ToolGroupSerializer, adapter: :attributes, scope: current_member
  end

  def show
    if !ToolGroup.manageable_by?(current_member, @group.shop_id) && (@group.disabled? || @group.included_tools.any?(&:disabled?))
      raise Error::NotFound.new
    end
    render_group(@group)
  end

  def create
    render_group(ToolGroupCatalog.save!(actor: current_member, attributes: group_params))
  end

  def update
    render_group(ToolGroupCatalog.save!(actor: current_member, group: @group,
      attributes: group_params, revision: params.require(:revision)))
  end

  def destroy
    ToolGroupCatalog.save!(actor: current_member, group: @group,
      attributes: { archived: true }, revision: params.require(:revision))
    ToolCheckoutRequest.where(tool_group_id: @group.id, status: 'deleted').each do |request|
      CheckoutCreation.notify { request.remove_announcement }
    end
    head :no_content
  end

  def review
    member = review_member
    review = ToolGroupCheckout.review(member: member, group: @group)
    payload = review.deep_transform_keys { |key| key.to_s.camelize(:lower) }
    payload['group'] = ActiveModelSerializers::SerializableResource.new(@group,
      serializer: ToolGroupSerializer, adapter: :attributes, scope: current_member).as_json
    payload['prerequisiteNames'] = Tool.where(:id.in => review[:prerequisite_ids]).map(&:name)
    render json: payload
  end

  def approve
    result = ToolGroupCheckout.approve!(actor: current_member, member: review_member,
      group: @group, revision: params.require(:revision), request_id: params[:request_id])
    render json: {
      checkouts: serialize_checkouts(result[:checkouts]), skipped: serialize_checkouts(result[:skipped]),
      approvalBatchId: result[:approval_batch_id]
    }
  end

  def volunteer
    request = ToolGroupVolunteering.create!(member: current_member, group: @group, note: params[:note])
    render json: volunteer_payload(request)
  end

  def volunteers
    raise Error::Forbidden.new unless CheckoutApproverVolunteering.reviewer?(current_member, @group.shop_id)
    render json: CheckoutApproverRequest.where(tool_group_id: @group.id, status: 'open').map { |row| volunteer_payload(row) }.to_json
  end

  def decide_volunteer
    request = CheckoutApproverRequest.find(params[:request_id])
    raise Error::NotFound.new unless request && request.tool_group_id == @group.id
    raise Error::UnprocessableEntity.new unless params[:decision].in?(%w[approved declined])
    ToolGroupVolunteering.decide!(request: request, actor: current_member,
      approve: params[:decision] == 'approved', note: params[:note])
    render json: volunteer_payload(request)
  end

  private

  def volunteer_payload(request)
    { id: request.id.to_s, status: request.status, memberName: request.member.fullname,
      note: request.note, requestDate: request.request_date, targetType: 'group', targetName: @group.name,
      toolGroupId: @group.id.to_s, groupRevision: @group.revision, includedToolIds: @group.included_tool_ids }
  end

  def review_member
    if params[:member_id].present? && params[:member_id].to_s != current_member.id.to_s
      raise Error::Forbidden.new unless ToolGroupCheckout.authorized?(current_member, @group)
      Member.find(params[:member_id]) || raise(Error::NotFound.new)
    else
      current_member
    end
  end

  def serialize_checkouts(rows)
    ActiveModelSerializers::SerializableResource.new(rows, each_serializer: ToolCheckoutSerializer,
      adapter: :attributes, scope: current_member).as_json
  end

  def find_group
    @group = ToolGroup.find(params[:id]) || raise(Error::NotFound.new)
  end

  def group_params
    params.permit(:shop_id, :name, :description, :reservable, :requestable, :announce,
      :announce_channel, prerequisite_ids: [], included_tool_ids: []).to_h.symbolize_keys
  end

  def render_group(group)
    render json: group, serializer: ToolGroupSerializer, adapter: :attributes, scope: current_member
  end
end
