class ToolGroupSerializer < ActiveModel::Serializer
  attributes :id, :shop_id, :name, :description, :prerequisite_ids, :included_tool_ids,
    :reservable, :requestable, :announce, :announce_channel, :archived, :revision
  attribute(:target_type) { 'group' }
  attribute(:can_manage) { ToolGroup.manageable_by?(scope, object.shop_id) }
  attribute(:can_approve) { ToolGroupCheckout.authorized?(scope, object) }
  attribute :can_request do
    begin
      review = ToolGroupCheckout.review(member: scope, group: object, requesting: true)
      review[:create_tool_ids].any? && review[:missing_prerequisite_ids].empty? &&
        !ToolCheckoutRequest.where(member_id: scope.id, tool_group_id: object.id, status: 'open').exists?
    rescue Error::UnprocessableEntity
      false
    end
  end
  attribute :included_tools do
    ActiveModelSerializers::SerializableResource.new(object.included_tools,
      each_serializer: ToolSerializer, adapter: :attributes, scope: scope).as_json
  end
end
