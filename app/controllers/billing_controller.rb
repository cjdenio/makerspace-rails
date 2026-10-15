class BillingController < AuthenticationController
  include BillingGate
  include BraintreeGateway
  include FastQuery::BraintreeQuery
end
