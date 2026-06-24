class ShopSerializer < ActiveModel::Serializer
  attributes :id, :name, :slack_channel, :disabled

  attribute :tool_count do
    object.tools.count
  end
end
