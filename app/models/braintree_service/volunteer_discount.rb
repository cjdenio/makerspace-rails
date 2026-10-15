# BraintreeService::VolunteerDiscount
#
# Applies billing-cycle-based volunteer discounts to a member's Braintree
# subscription. Each call adds num_cycles of the configured discount.
#
# Cycles accumulate on the subscription: if a member has 2 cycles queued and
# earns another discount, they end up with 3 cycles queued. Braintree applies
# one cycle per billing date and decrements automatically.
#
class BraintreeService::VolunteerDiscount

  # Applies num_cycles of discount_id to member's subscription.
  #
  # Returns a result hash on success:
  #   {
  #     cycles_added:  Integer,  # cycles added this call
  #     total_cycles:  Integer,  # total cycles now queued
  #     amount:        Float,    # per-cycle dollar amount from Braintree
  #     description:   String    # human-readable discount description
  #   }
  #
  # Returns :no_subscription if member.subscription_id is blank.
  # Raises Error::Braintree::Result on Braintree API failure.
  #
  def self.apply(member, discount_id, num_cycles = 1)
    return :no_subscription unless member.subscription_id.present?

    gateway = ::Service::BraintreeGateway.connect_gateway

    # Fetch current subscription to detect existing discount and cycle count
    subscription   = gateway.subscription.find(member.subscription_id)
    existing       = subscription.discounts.find { |d| d.id == discount_id }
    existing_cycles = existing ? existing.number_of_billing_cycles.to_i : 0
    new_total       = existing_cycles + num_cycles

    update_params = if existing
      {
        discounts: {
          update: [{ existing_id: discount_id, number_of_billing_cycles: new_total }]
        }
      }
    else
      {
        discounts: {
          add: [{ inherited_from_id: discount_id, number_of_billing_cycles: num_cycles }]
        }
      }
    end

    result = gateway.subscription.update(member.subscription_id, update_params)
    raise ::Error::Braintree::Result.new(result) unless result.success?

    # Fetch discount catalogue for human-readable description
    all_discounts = gateway.discount.all
    discount      = all_discounts.find { |d| d.id == discount_id }

    {
      cycles_added: num_cycles,
      total_cycles: new_total,
      amount:       discount ? discount.amount.to_f : 0.0,
      description:  (discount && (discount.description.presence || discount.name.presence)) || discount_id
    }
  end
end
