class RentalSpotSerializer < ActiveModel::Serializer
  attributes :id,
             :number,
             :location,
             :description,
             :rental_type_id,
             :rental_type_display_name,
             :requires_approval,
             :active,
             :parent_number,
             :notes,
             :available,
             :invoice_option_id,
             :invoice_option_name,
             :invoice_option_amount,
             :invoice_option_plan_id

  def available
    object.available?
  end

  def rental_type_display_name
    object.rental_type&.display_name
  end

  def invoice_option_id
    object.invoice_option&.id&.to_s
  end

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
