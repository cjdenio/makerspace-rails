require 'rails_helper'

RSpec.describe Admin::Billing::TransactionsController, type: :controller do
  let(:gateway) { double }
  let(:non_customer) { create(:member) }
  let(:member) { create(:member, customer_id: "bar") }
  let(:payment_method) { build(:credit_card, customer_id: "bar") }
  let(:invoice) { create(:invoice, member: member) }
  let(:transaction) { build(:transaction) }
  let(:discount_id) { generate(:uid) }
  let(:discounted_transaction) { build(:transaction, discounts: [{
    id: discount_id,
    name: "10% Discount",
    description: "A discount for 10%",
    amount: "6.50",
  }]) }
  let(:admin) { create(:member, :admin) }

  let(:valid_params) {
    {
      payment_method_id: "foo",
      invoice_id: invoice.id
    }
  }

  before(:each) do
    create(:permission, member: admin, name: :billing, enabled: true )
    allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in admin
  end

  describe "GET #index" do
    let(:transaction) { build(:transaction) }
    let(:related_invoice) { create(:invoice, transaction_id: transaction.id) }
    it "renders a list of transactions" do
      related_invoice # call to initialize
      allow(BraintreeService::Transaction).to receive(:get_transactions).with(gateway, anything, anything, nil).and_return([transaction])
      expect(BraintreeService::Transaction).to receive(:get_transactions).with(gateway, anything, anything, nil).and_return([transaction])

      get :index, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response.first['id']).to eq(transaction.id)
      expect(parsed_response.first['invoice']['id']).to eq(related_invoice.id.to_s)
    end

    it "filters transactions by discount IDs" do
      related_invoice # call to initialize
      expect(BraintreeService::Transaction).to receive(:get_transactions).with(gateway, anything, 1, kind_of(Proc)) do |_gateway, _query, _limit, filter|
        [transaction, discounted_transaction].select { |candidate| filter.call(candidate) }
      end

      get :index, params: { discount_id: [discount_id], limit: 1 }, format: :json
      expect(response).to have_http_status(200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response.first['id']).to eq(discounted_transaction.id)
      expect(parsed_response.length).to eq(1)
    end

    it "applies amount filters and the requested result limit" do
      amount_search = double
      search = double(amount: amount_search)

      expect(amount_search).to receive(:between).with("10.25", "99.50")
      expect(BraintreeService::Transaction).to receive(:get_transactions).with(gateway, kind_of(Proc), 12, nil) do |_gateway, query, _limit, _filter|
        query.call(search)
        []
      end

      get :index, params: { min_amount: "10.25", max_amount: "99.50", limit: "12" }, format: :json

      expect(response).to have_http_status(200)
    end

    it "applies amount filters sent as camelCase (React's raw-request escape hatch)" do
      amount_search = double
      search = double(amount: amount_search)

      expect(amount_search).to receive(:between).with("10.25", "99.50")
      expect(BraintreeService::Transaction).to receive(:get_transactions).with(gateway, kind_of(Proc), 12, nil) do |_gateway, query, _limit, _filter|
        query.call(search)
        []
      end

      get :index, params: { minAmount: "10.25", maxAmount: "99.50", limit: "12" }, format: :json

      expect(response).to have_http_status(200)
    end

    it "rejects a non-positive result limit" do
      get :index, params: { limit: "0" }, format: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)["message"]).to match(/positive integer/i)
    end
  end

  describe "GET #show" do
    it "renders a transaction" do
      allow(BraintreeService::Transaction).to receive(:get_transaction).with(gateway, "foo").and_return(transaction)
      expect(BraintreeService::Transaction).to receive(:get_transaction).with(gateway, "foo").and_return(transaction)

      get :show, params: { id: "foo" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq(transaction.id)
    end
  end

  describe "DELETE #destroy" do
    it "refunds the requested transaction" do
      allow(::BraintreeService::Transaction).to receive(:refund).with(gateway, transaction.id)
      expect(::BraintreeService::Transaction).to receive(:refund).with(gateway, transaction.id)
      delete :destroy, params: { id: transaction.id }, format: :json
      expect(response).to have_http_status(204)
    end

    it "logs the refund against the linked invoice and member when one exists" do
      linked_invoice = create(:invoice, member: member, transaction_id: transaction.id, amount: 74.99)
      allow(::BraintreeService::Transaction).to receive(:refund).with(gateway, transaction.id)
      expect(Service::AuditLogger).to receive(:log).with(
        hash_including(
          resource_type: 'Invoice',
          resource_id: linked_invoice.id,
          subject: member,
          message_details: a_string_matching(/Braintree invoice ID: #{linked_invoice.id}.*resource class: #{linked_invoice.resource_class}.*74\.99/)
        )
      )

      delete :destroy, params: { id: transaction.id }, format: :json
      expect(response).to have_http_status(204)
    end

    it "falls back to logging against the admin when no invoice is linked to the transaction" do
      allow(::BraintreeService::Transaction).to receive(:refund).with(gateway, transaction.id)
      expect(Service::AuditLogger).to receive(:log).with(
        hash_including(
          resource_type: 'Transaction',
          resource_id: admin.id,
          subject: nil,
          message_details: a_string_matching(/No invoice found/)
        )
      )

      delete :destroy, params: { id: transaction.id }, format: :json
      expect(response).to have_http_status(204)
    end
  end
end
