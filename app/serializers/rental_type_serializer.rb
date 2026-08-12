class RentalTypeSerializer < ActiveModel::Serializer
  attributes :id,
             :display_name,
             :active,
             :invoice_option_id,
             :invoice_option_name,
             :invoice_option_amount,
             :invoice_option_plan_id

  def invoice_option_name
    object.invoice_option&.name
  end

  def invoice_option_amount
    object.invoice_option&.amount
  end

  def invoice_option_plan_id
    object.invoice_option&.plan_id
  end
end
