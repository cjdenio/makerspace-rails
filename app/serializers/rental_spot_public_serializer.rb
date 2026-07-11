class RentalSpotPublicSerializer < ActiveModel::Serializer
  attributes :id,
             :number,
             :location,
             :description,
             :rental_type_display_name,
             :requires_approval,
             :active,
             :available,
             :invoice_option_name,
             :invoice_option_amount

  def available
    object.available?
  end

  def rental_type_display_name
    object.rental_type&.display_name
  end

  def invoice_option_name
    object.invoice_option&.name
  end

  def invoice_option_amount
    object.invoice_option&.amount
  end
end
