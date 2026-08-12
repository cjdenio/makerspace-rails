class MemberSerializer < MemberSummarySerializer
  attributes :card_id,
             :totp_enabled,
             :member_contract_signed_date,
             :subscription,
             :subscription_id,
             :earned_membership_id,
             :customer_id,
             :address,
             :phone,
             :silence_emails,
             :member_contract_on_file,
             :group_name,
             :household_role,
             :subscription_plan_id

  attribute :expiring_payment_card_types, if: :include_expiring_payment_card_types?

  def totp_enabled
    object.otp_required_for_login? && object.otp_secret_encrypted.present?
  end

  def card_id
    active_card = object.access_cards.to_a.find { |card| card.is_active? }
    active_card && active_card.id
  end

  def earned_membership_id
    object.earned_membership && object.earned_membership.id
  end

  def group_name
    object.groupName
  end

  def household_role
    object.household_role
  end

  def subscription_plan_id
    return nil unless object.subscription_id
    invoice = Invoice.find_by(subscription_id: object.subscription_id)
    invoice&.plan_id
  end

  def expiring_payment_card_types
    @expiring_payment_card_types ||= Service::CardExpirationCheck.card_types_for_member(object.id)
  end

  def include_expiring_payment_card_types?
    viewer = instance_options[:viewer]
    return false unless viewer
    authorized = viewer.id == object.id || %w[admin board_member].include?(viewer.role)
    authorized && expiring_payment_card_types.present?
  end

  def address
    {
      street: object.address_street,
      unit: object.address_unit,
      city: object.address_city,
      state: object.address_state,
      postal_code: object.address_postal_code
    }
  end
end
