require 'swagger_helper'

describe 'Billing::Subscriptions API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:basic) { create(:member) }
  let(:success_result) { double("success", success?: true )}

  let(:invoice) { create(:invoice, member: basic) }
  let(:subscriptions) { build_list(:subscription, 3, id: invoice.generate_subscription_id) }
  let(:gateway) { double }
  before do 
    create(:permission, member: admin, name: :billing, enabled: true )
    create(:permission, member: basic, name: :billing, enabled: true )
    allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
  end

  path '/admin/billing/subscriptions' do 
    get 'Lists subscription' do 
      tags 'Subscriptions'
      operationId "adminListSubscriptions"
      parameter name: :startDate, in: :query, type: :string, required: false
      parameter name: :endDate, in: :query, type: :string, required: false
      parameter name: :search, in: :query, type: :string, required: false
      parameter name: :planId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :subscriptionStatus, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :customerId, in: :query, type: :string, required: false

      response '200', 'subscription found' do 
        before do 
          sign_in admin
          allow(BraintreeService::Subscription).to receive(:get_subscriptions).with(gateway, anything).and_return(subscriptions)
        end

        schema type: :array,
            items: { '$ref' => '#/components/schemas/Subscription' }

        run_test!
      end

      response '401', 'User not authenticated' do 
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '403', 'User not authorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/admin/billing/subscriptions/{id}' do
    delete 'Cancels a subscription' do 
      let(:subscription) { build(:subscription, id: "foo") }
      before do 
        allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, subscription.id).and_return(subscription)
        allow(BraintreeService::Subscription).to receive(:cancel).with(gateway, subscription.id).and_return(success_result)
      end

      tags 'Subscriptions'
      operationId "adminCancelSubscription"
      parameter name: :id, in: :path, type: :string

      response '204', 'refund requested' do
        before { sign_in admin }

        let(:id) { subscription.id }
        run_test!
      end

      response '401', 'User not authenticated' do 
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '403', 'User not authorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end
    end
  end

  # The existing '200' spec above stubs get_subscriptions with `anything`,
  # which never verifies what query was actually constructed — exactly why
  # the bug this covers went unnoticed. construct_query is private, so it's
  # exercised directly here via #send rather than through a full request,
  # using a recording double in place of Braintree's real search builder.
  describe '#construct_query' do
    let(:controller) { Admin::Billing::SubscriptionsController.new }

    it 'narrows results to the matching member when search matches a Member' do
      target = create(:member, subscription_id: 'sub_target_123')
      allow(controller).to receive(:subscription_query_params)
        .and_return({ search: 'sub_target_123' })

      search = double('search')
      ids    = double('ids')
      allow(search).to receive(:ids).and_return(ids)
      expect(ids).to receive(:in).with(['sub_target_123'])

      controller.send(:construct_query).call(search)
    end

    it 'does not silently return an unfiltered query when the initial Member lookup is empty' do
      # Regression for the ||= bug: Mongoid::Criteria is never nil even when
      # it matches zero records, so `resources ||= Rental.where(...)` could
      # never reassign and the search filter was silently dropped entirely,
      # returning every subscription instead of narrowing to a match.
      rental = create(:rental, subscription_id: 'sub_rental_456')
      allow(controller).to receive(:subscription_query_params)
        .and_return({ search: 'sub_rental_456' })

      search = double('search')
      ids    = double('ids')
      allow(search).to receive(:ids).and_return(ids)
      expect(ids).to receive(:in).with(['sub_rental_456'])

      controller.send(:construct_query).call(search)
    end
  end
end
