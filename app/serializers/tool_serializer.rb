class ToolSerializer < ActiveModel::Serializer
  attributes :id, :name, :description, :disabled, :shop_id, :prerequisite_ids

  attribute :shop_name do
    object.shop.try(:name)
  end

  attribute :prerequisite_names do
    object.prerequisites.map(&:name)
  end
end
