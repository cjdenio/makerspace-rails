class Billing::PaymentMethodsController < BillingController
  # Allow unauthenticated access to new — needed for self-registration payment step
  # The client token is generated without a customer_id for unauthenticated requests.
  # Also skip verify_billing_permission (added to BillingController via BillingGate):
  # current_member is nil for this anonymous request, and BillingGate#verify_billing_permission
  # calls current_member.is_allowed? with no nil-guard, which would raise NoMethodError
  # instead of returning the anonymous client token — breaking self-registration entirely.
  skip_before_action :authenticate_member!, only: [:new]
  skip_before_action :authenticated?, only: [:new]
  skip_before_action :verify_billing_permission, only: [:new]

  before_action :payment_method_params, only: [:create]

  def new
    client_token = generate_client_token
    render json: { clientToken: client_token } and return
  end

  def create
    payment_method_nonce = payment_method_params[:payment_method_nonce]

    # Create a member w/ this payment method if not a customer yet
    if current_member.customer_id.nil?
      result = @gateway.customer.create(
        first_name: current_member.firstname,
        last_name: current_member.lastname,
        email: current_member.email,
        payment_method_nonce: payment_method_nonce,
      )
      current_member.update_attributes!({ customer_id: result.customer.id }) if result.success?

    # Add this payment method to customer if already customer
    else
      result = @gateway.payment_method.create(
        customer_id: current_member.customer_id,
        payment_method_nonce: payment_method_nonce,
        options: {
          make_default: payment_method_params[:make_default] || false
        }
      )
    end

    # Parse Braintree result
    raise Error::Braintree::Result.new(result) unless result.success?
    payment_method = result.try(:payment_method) ? result.payment_method : result.customer.payment_methods.first

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'payment_method_added',
      resource_type:  'PaymentMethod',
      resource_id:    current_member.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { token: payment_method.token, last_4: payment_method.try(:last_4) }
    )

    render json: payment_method, serializer: BraintreeService::PaymentMethodSerializer, adapter: :attributes, status: 200 and return
  end

  def index
    if current_member.customer_id.nil?
      payment_methods = []
    else
      payment_methods = ::BraintreeService::PaymentMethod.get_payment_methods_for_customer(@gateway, current_member.customer_id)
    end
    render json: payment_methods, each_serializer: BraintreeService::PaymentMethodSerializer, status: 200, adapter: :attributes and return
  end

  def show
    payment_method_token = params[:id]
    raise Error::Braintree::MissingCustomer.new unless current_member.customer_id
    # Only allowed to modify own payment methods
    payment_method = ::BraintreeService::PaymentMethod.find_payment_method_for_customer(@gateway, payment_method_token, current_member.customer_id)
    render json: payment_method, serializer: BraintreeService::PaymentMethodSerializer, adapter: :attributes, status: 200 and return
  end

  def destroy
    payment_method_token = params[:id]
    raise Error::Braintree::MissingCustomer.new unless current_member.customer_id
    # Only allowed to modify own payment methods
    payment_method = ::BraintreeService::PaymentMethod.find_payment_method_for_customer(@gateway, payment_method_token, current_member.customer_id)

    sub_ids = []

    unless current_member.subscription_id.nil?
      membership_sub = ::BraintreeService::Subscription.get_subscription(@gateway, current_member.subscription_id)
      sub_ids.push(membership_sub.id) if membership_sub.payment_method_token == payment_method_token
    end

    current_member.rentals.each do |rental|
      rental_sub = ::BraintreeService::Subscription.get_subscription(@gateway, rental.subscription_id) unless rental.subscription_id.nil?
      sub_ids.push(rental_sub.id) if rental_sub.payment_method_token == payment_method_token
    end

    result = ::BraintreeService::PaymentMethod.delete_payment_method(@gateway, payment_method.token)
    raise Error::Braintree::Result.new(result) unless result.success?

    # Destroy the related invoices that were cancelled due to payment method being removed
    sub_ids.each do |id|
      invoice = Invoice.find_by(subscription_id: id)
      Invoice.process_cancellation(invoice.id)
    end

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'payment_method_removed',
      resource_type:  'PaymentMethod',
      resource_id:    current_member.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { token: payment_method.token,
                        subscriptions_cancelled: sub_ids }
    )

    render json: {}, status: 204 and return
  end

  private

  def payment_method_params
    params.require(:payment_method_nonce)
    params.permit(:payment_method_nonce, :make_default)
  end

  def generate_client_token
    options = {}
    # Only include customer_id if authenticated and member has one
    begin
      options[:customer_id] = current_member.customer_id if current_member&.customer_id.present?
    rescue
      # Unauthenticated — generate token without customer_id
    end
    @gateway.client_token.generate(options)
  rescue Braintree::BraintreeError => e
    Honeybadger.notify(e)
    raise Error::InternalServerError.new("Failed to initialize payment form")
  end
end
