class ToolCheckoutSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :tool_id, :checked_out_at, :revoked_at,
             :revocation_reason, :signed_off_via, :approved_by_id

  attribute :tool_name do
    object.tool.try(:name)
  end

  attribute :shop_name do
    object.tool.try(:shop).try(:name)
  end

  attribute :shop_id do
    object.tool.try(:shop_id)
  end

  attribute :member_name do
    object.member.try(:fullname)
  end

  attribute :member_email do
    object.member.try(:email)
  end

  attribute :approved_by_name do
    object.approved_by.try(:fullname)
  end

  attribute :active do
    object.active?
  end
end
