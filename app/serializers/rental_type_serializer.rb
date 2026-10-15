class RentalTypeSerializer < ActiveModel::Serializer
  attributes :id,
             :display_name,
             :active,
             :invoice_option_id,
             :invoice_option_name,
             :invoice_option_amount,
             :invoice_option_quantity,
             :invoice_option_plan_id

  def invoice_option_name
    object.invoice_option&.name
  end

  def invoice_option_amount
    object.invoice_option&.amount
  end

  # Months this charge covers -- for a subscription-backed option (has a
  # plan_id) this is the actual recurring billing interval, copied from the
  # Braintree plan's billingFrequency when the plan was attached (see
  # ui/billing/BillingForm.tsx's planToOptionMap). For a one-time option it's
  # just how many months the single payment covers, not a recurring cadence.
  def invoice_option_quantity
    object.invoice_option&.quantity
  end

  def invoice_option_plan_id
    object.invoice_option&.plan_id
  end
end
