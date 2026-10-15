class CheckoutApproverSerializer < ActiveModel::Serializer
  attribute(:out_of_service_tool_names) do
    scoped_tools.select(&:out_of_service).map(&:name)
  end
  attribute :tools do
    scoped_tools.map { |tool| { id: tool.id.to_s, name: tool.name, shopId: tool.shop_id.to_s, outOfService: !!tool.out_of_service } }
  end
  attribute :tool_groups do
    groups = checkout_context ? checkout_context.groups_for(object.tool_group_ids) : ToolGroup.where(:id.in => object.tool_group_ids).to_a
    groups.map { |group| { id: group.id.to_s, name: group.name, shopId: group.shop_id.to_s } }
  end
  attributes :id, :member_id, :shop_ids, :tool_ids, :tool_group_ids

  attribute :member_name do
    (checkout_context ? checkout_context.members[object.member_id.to_s] : object.member).try(:fullname)
  end

  attribute :member_email do
    (checkout_context ? checkout_context.members[object.member_id.to_s] : object.member).try(:email)
  end

  attribute :shop_names do
    checkout_context ? checkout_context.shop_names(object.shop_ids) : object.shops.map(&:name)
  end

  attribute :tool_names do
    checkout_context ? checkout_context.names(object.tool_ids) : object.tools.map(&:name)
  end

  def checkout_context
    instance_options[:checkout_context]
  end

  def scoped_tools
    checkout_context ? checkout_context.tools_for(object.tool_ids) : object.tools.to_a
  end
end
