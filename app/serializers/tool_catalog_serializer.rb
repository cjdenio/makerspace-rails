class ToolCatalogSerializer < ActiveModel::Serializer
  attributes :id, :name, :description, :shop_id, :shop_name, :prerequisite_ids,
             :prerequisite_names, :unmet_prerequisite_ids,
             :unmet_prerequisite_names, :requestable

  def shop_name
    object.shop.try(:name)
  end

  def prerequisite_names
    object.prerequisites.map(&:name)
  end

  def unmet_prerequisite_ids
    checked_out_tool_ids = ToolCheckout.where(member_id: scope.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    object.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_tool_ids.include?(pid) }
  end

  def unmet_prerequisite_names
    Tool.where(:id.in => unmet_prerequisite_ids).map(&:name)
  end

  def requestable
    true
  end
end
