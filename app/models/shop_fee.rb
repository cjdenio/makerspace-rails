# app/models/shop_fee.rb
#
# Stub model used as the resource_class target for one-off shop charge invoices.
# Invoices with resource_class: "fee" point here via resource_id == member_id.
# execute_invoice_operation is intentionally a no-op — shop fees do NOT renew
# or alter membership expiry. They are pure Braintree payment-collection invoices.
#
class ShopFee
  # Minimal interface required by Invoice#execute_invoice_operation and
  # Invoice#resource_name so the rest of the invoice lifecycle works unchanged.

  attr_reader :id

  def initialize(id)
    @id = id
  end

  # Called by Invoice to look up the resource. We store member_id as resource_id
  # so we can always resolve the owning member.
  def self.find(id)
    new(id)
  end

  # Invoice calls resource.execute_operation(operation, invoice) — no-op for fees.
  def execute_operation(_operation, _invoice)
    true
  end

  # Invoice calls resource.reverse_operation — no-op for fees.
  def reverse_operation(_operation, _invoice)
    true
  end

  # Used by Invoice#resource_name in serializer.
  def fullname
    nil
  end

  # Invoice checks for delay_invoice_operation — fees never delay.
  def delay_invoice_operation(_operation)
    false
  end

  # Invoice checks for send_renewal_slack_message — no-op for fees.
  def send_renewal_slack_message; end
  def send_renewal_reversal_slack_message; end

  # Invoice checks for subscription field — fees have none.
  def subscription; nil; end
  def remove_subscription; end
end
