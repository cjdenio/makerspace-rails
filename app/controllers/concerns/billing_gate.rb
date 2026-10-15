module BillingGate
  extend ActiveSupport::Concern

  included do
    before_action :verify_billing_permission
  end

  def verify_billing_permission
    # Unauthenticated requests (e.g. Billing::PaymentMethodsController#new
    # during self-registration, before a member account exists) are not
    # this check's concern — they're gated by their own action-level
    # skip_before_action calls for authenticate_member!/authenticated?.
    # Without this guard, an unauthenticated request reaching this filter
    # raises NoMethodError on nil.is_allowed? instead of being handled by
    # whatever auth gate the action actually intends, which is exactly
    # the regression this guard prevents.
    return if current_member.nil?

    raise Error::Forbidden.new unless current_member.is_allowed?(
      DefaultPermission::WHITELISTS[:billing])
  end
end
