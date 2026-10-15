# mock nonce from braintree  as appropriate
# "fake-valid-nonce"
# "fake-valid-no-billing-address-nonce"
# "fake-valid-visa-nonce"
# "fake-paypal-one-time-nonce"
# "fake-paypal-billing-agreement-nonce"
# "fake-processor-declined-visa-nonce"
# "fake-consumed-nonce"


#make transaction
# sale_result = gateway.transaction.sale(
#   amount: 100
#   payment_method_nonce: something
#   options: {
#     submit_for_settlement: true
#   }
# )

# Settle it
# result = gateway.testing.settle(sale_result.transaction.id)
# result.success?.should == true
# result.transaction.status.should == Braintree::Transactioon::Status::Settled


# # Decline it
# result = gateway.testing.settlement_delcine(sale_result.transaction.id)
# result.success?.should == true
# result.transaction.status.should == Braintree::Transactioon::Status::SettlmentDeclined



# instantly disputed transaction of any mount:
# test card number === 4023898493988028


require 'rails_helper'

RSpec.describe Billing::PaymentMethodsController, type: :controller do
  let(:gateway) { double("Gateway") }
  let(:non_customer) { create(:member) }
  let(:member) { create(:member, customer_id: "bar") }
  let(:payment_method) { build(:credit_card) }
  let(:invoice) { create(:invoice, member: member) }
  let(:subscription) { build(:subscription, id: "foobar") }

  let(:failed_result) { double("Failed", success?: false) }
  let(:success_result) { double("Success", success?: true) }

  let(:valid_params) {
    { 
      payment_method_nonce: "some_nonce",
      make_default: true,
    }
  }

  before(:each) do
    create(:billing_permission, member: member)
    create(:billing_permission, member: non_customer)
    allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in member
  end

  describe "GET #new" do 
    it "generates a client token" do 
      allow(gateway).to receive_message_chain(:client_token, :generate).and_return("some_token")
      expect(gateway).to receive_message_chain(:client_token, :generate).and_return("some_token")

      get :new, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['clientToken']).to eq("some_token")
    end
  end

  describe "GET #index" do 
    it "fetches payment methods for customer" do 
      allow(::BraintreeService::PaymentMethod).to receive(:get_payment_methods_for_customer).with(gateway, "bar").and_return([payment_method])
      expect(::BraintreeService::PaymentMethod).to receive(:get_payment_methods_for_customer).with(gateway, "bar").and_return([payment_method])
      get :index, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response.first['id']).to eq(payment_method.token)
    end

    it "renders an empty list if current member is not a customer" do 
      sign_in non_customer
      expect(::BraintreeService::PaymentMethod).not_to receive(:get_payment_methods_for_customer)
      get :index, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response).to eq([])
    end
  end


  describe "GET #show" do
    it "renders found payment method" do
      token = "foo"
      allow(::BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, token, member.customer_id).and_return(payment_method)
      expect(::BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, token, member.customer_id).and_return(payment_method)
      
      get :show, params: {id: token}, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq(payment_method.token)
    end

    it "raises error if no customer" do
      sign_in non_customer
      get :show, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end
  end

  describe "POST #create" do 
    it "creates payment method for customer" do 
      expect(gateway).not_to receive(:customer)
      expect(gateway).to receive_message_chain(:payment_method, create: success_result)
      expect(success_result).to receive(:try).with(:payment_method).and_return(true)
      expect(success_result).to receive(:payment_method).and_return(payment_method)

      post :create, params: valid_params, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq(payment_method.token)
    end

    it "creates a customer with new payment method if not already a customer" do 
      sign_in non_customer
      allow(gateway).to receive_message_chain(:customer, create: success_result)
      expect(gateway).to receive_message_chain(:customer, create: success_result)
      expect(gateway).not_to receive(:payment_method)
      
      allow(success_result).to receive_message_chain(:customer, id: "new_customer")
      expect(success_result).to receive_message_chain(:customer, id: "new_customer")

      allow(success_result).to receive(:payment_method).and_return(false)
      allow(success_result).to receive_message_chain(:customer, :payment_methods, first: payment_method)

      post :create, params: valid_params, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq(payment_method.token)

      non_customer.reload
      expect(non_customer.customer_id).to eq("new_customer")
    end

    it "renders error if no nonce is provided" do 
      post :create, params: { make_default: true }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(422)
      expect(parsed_response['message']).to match(/payment_method_nonce/i)
    end

    it "raises error if create failed" do 
      allow(gateway).to receive_message_chain(:payment_method, create: failed_result)
      expect(gateway).to receive_message_chain(:payment_method, create: failed_result)
      allow(Error::Braintree::Result).to receive(:new).with(failed_result).and_return(Error::Braintree::Result.new) # Bypass error instantiation
      
      post :create, params: valid_params, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(503)
      expect(parsed_response['message']).to match(/service unavailable/i)
    end
  end

  describe "GET #cancellation_impact" do
    it "reports no impact when the payment method isn't attached to any subscription" do
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)

      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['membership']).to eq(false)
      expect(parsed_response['rentalCount']).to eq(0)
      expect(parsed_response['membershipSubscriptionId']).to be_nil
      expect(parsed_response['rentalSubscriptionIds']).to eq([])
    end

    it "reports membership impact when the payment method matches the member's subscription" do
      member.update_attributes!(subscription_id: "member_sub_1")
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "member_sub_1").and_return(
        build(:subscription, id: "member_sub_1", payment_method_token: "foobar")
      )

      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['membership']).to eq(true)
      expect(parsed_response['rentalCount']).to eq(0)
      expect(parsed_response['membershipSubscriptionId']).to eq("member_sub_1")
      expect(parsed_response['rentalSubscriptionIds']).to eq([])
    end

    it "reports rental impact when the payment method matches a rental's subscription" do
      create(:rental, member: member, subscription_id: "rental_sub_1")
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "rental_sub_1").and_return(
        build(:subscription, id: "rental_sub_1", payment_method_token: "foobar")
      )

      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['membership']).to eq(false)
      expect(parsed_response['rentalCount']).to eq(1)
      expect(parsed_response['membershipSubscriptionId']).to be_nil
      expect(parsed_response['rentalSubscriptionIds']).to eq(["rental_sub_1"])
    end

    it "raises error if no customer" do
      sign_in non_customer
      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end

    it "does not raise when the member's subscription_id is orphaned in Braintree" do
      member.update_attributes!(subscription_id: "stale_sub")
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "stale_sub").and_raise(Braintree::NotFoundError)

      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['membership']).to eq(false)
      expect(parsed_response['rentalCount']).to eq(0)
    end

    it "does not raise when a rental's subscription_id is orphaned in Braintree" do
      create(:rental, member: member, subscription_id: "stale_rental_sub")
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "stale_rental_sub").and_raise(Braintree::NotFoundError)

      get :cancellation_impact, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['membership']).to eq(false)
      expect(parsed_response['rentalCount']).to eq(0)
    end
  end

  describe "DELETE #destroy" do
    it "deletes payment method for member" do
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      expect(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)

      allow(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(success_result)
      expect(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(success_result)

      delete :destroy, params: { id: "foobar" }, format: :json
      expect(response).to have_http_status(204)
    end

    it "cancels the membership invoice when the deleted payment method matches the member's subscription" do
      member.update_attributes!(subscription_id: "member_sub_1")
      matching_invoice = create(:invoice, member: member, subscription_id: "member_sub_1")

      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "member_sub_1").and_return(
        build(:subscription, id: "member_sub_1", payment_method_token: "foobar")
      )
      allow(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(success_result)
      expect(Invoice).to receive(:process_cancellation).with(matching_invoice.id)

      delete :destroy, params: { id: "foobar" }, format: :json
      expect(response).to have_http_status(204)
    end

    it "raises error if delete failed" do 
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      expect(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)

      allow(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(failed_result)
      expect(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(failed_result)
      allow(Error::Braintree::Result).to receive(:new).with(failed_result).and_return(Error::Braintree::Result.new) # Bypass error instantiation
      
      delete :destroy, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(503)
      expect(parsed_response['message']).to match(/service unavailable/i)
    end

    it "raises error if no customer" do
      sign_in non_customer
      delete :destroy, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end

    it "still deletes the payment method when the member's subscription_id is orphaned in Braintree" do
      member.update_attributes!(subscription_id: "stale_sub")
      allow(BraintreeService::PaymentMethod).to receive(:find_payment_method_for_customer).with(gateway, "foobar", "bar").and_return(payment_method)
      allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "stale_sub").and_raise(Braintree::NotFoundError)
      allow(BraintreeService::PaymentMethod).to receive(:delete_payment_method).with(gateway, payment_method.token).and_return(success_result)

      delete :destroy, params: { id: "foobar" }, format: :json
      expect(response).to have_http_status(204)
    end
  end
end
