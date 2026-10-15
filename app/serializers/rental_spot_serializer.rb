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
             :invoice_option_quantity,
             :invoice_option_plan_id

  def available
    return instance_options[:availability_by_number][object.number] if instance_options.key?(:availability_by_number)

    object.available?
  end

  def rental_type_display_name
    rental_type&.display_name
  end

  def invoice_option_id
    invoice_option&.id&.to_s
  end

  def invoice_option_name
    invoice_option&.name
  end

  def invoice_option_amount
    invoice_option&.amount
  end

  # See RentalTypeSerializer#invoice_option_quantity for what this represents.
  def invoice_option_quantity
    invoice_option&.quantity
  end

  def invoice_option_plan_id
    invoice_option&.plan_id
  end

  private

  def rental_type
    return object.rental_type unless instance_options.key?(:rental_types_by_id)

    instance_options[:rental_types_by_id][object.rental_type_id.to_s]
  end

  def invoice_option
    return object.invoice_option unless instance_options.key?(:invoice_options_by_id)

    instance_options[:invoice_options_by_id][rental_type&.invoice_option_id.to_s]
  end
end
