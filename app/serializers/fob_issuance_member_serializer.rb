# Identity fields a fob issuer needs to check a member's ID. Deliberately no billing,
# subscription, notes or provisioning data.
class FobIssuanceMemberSerializer < ActiveModel::Serializer
  attributes :id, :firstname, :lastname, :email, :phone, :status, :expiration_time,
             :address_street, :address_unit, :address_city, :address_state,
             :address_postal_code, :member_contract_on_file

  def expiration_time
    object.expirationTime
  end

  def member_contract_on_file
    object.member_contract_signed_date.present?
  end
end
