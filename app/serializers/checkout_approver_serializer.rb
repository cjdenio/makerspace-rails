class CheckoutApproverSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :shop_ids

  attribute :member_name do
    object.member.try(:fullname)
  end

  attribute :member_email do
    object.member.try(:email)
  end

  attribute :shop_names do
    object.shops.map(&:name)
  end
end
