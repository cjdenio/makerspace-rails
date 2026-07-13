class BraintreeService::VenmoAccount < Braintree::VenmoAccount
  include ActiveModel::Serializers::JSON

  def self.new(gateway, args)
    super(gateway, args)
  end
end
