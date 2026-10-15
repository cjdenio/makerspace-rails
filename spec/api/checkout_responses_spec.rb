require 'swagger_helper'

RSpec.describe 'Checkout response contracts', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:tool) { create(:tool, shop: create(:shop), out_of_service: true) }
  let(:checkout) { ToolCheckout.create!(member: member, tool: tool, approved_by: member) }
  let(:request_record) { ToolCheckoutRequest.create!(member_id: member.id, tool_id: tool.id, note: 'Training please', request_date: Time.current, status: 'open') }
  before do
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
    allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
    allow_any_instance_of(ToolCheckout).to receive(:announce_checkout_success)
    allow_any_instance_of(ToolCheckout).to receive(:send_revocation_slack_notification)
    allow_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
  end

  { '/tool_checkouts' => 'ToolCheckout', '/admin/tool_checkouts' => 'ToolCheckout',
    '/tool_checkout_requests' => 'ToolCheckoutRequest', '/admin/tool_checkout_requests' => 'ToolCheckoutRequest' }.each do |route, model|
    path route do
      get "List authorized #{model} records with tool availability" do
        tags 'Tool checkouts'
        security [sessionAuth: []]
        produces 'application/json'
        if route == '/admin/tool_checkouts'
          parameter name: :member_id, in: :query, type: :string, required: false
          parameter name: :tool_id, in: :query, type: :string, required: false
          parameter name: :shop_id, in: :query, type: :string, required: false
          parameter name: :active, in: :query, type: :string, required: false, enum: %w[true false],
                    description: 'true: only checkouts that are not revoked; false: only revoked ones'
          parameter name: :active_members_only, in: :query, type: :string, required: false, enum: %w[true],
                    description: 'true: only checkouts held by members with an active membership status and an unexpired term (Member#active_unexpired?). Omitted: every member.'
        end
        response '200', 'Authorized records' do
          schema type: :array, items: { '$ref' => "#/components/schemas/#{model}" }
          before { model == 'ToolCheckout' ? checkout : request_record }
          run_test! do |response|
            expect(JSON.parse(response.body).first.fetch('outOfService')).to eq(true)
          end
        end
      end
    end
  end
  path '/admin/tool_checkouts' do
    post 'Grant a checkout' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: %w[member_id tool_id], properties: { member_id: { type: :string }, tool_id: { type: :string } } }
      let(:body) { { member_id: member.id.to_s, tool_id: tool.id.to_s } }
      response('200', 'Granted checkout and unmet prerequisite names') do
        schema allOf: [{ '$ref' => '#/components/schemas/ToolCheckout' }, { type: :object, properties: { unmet_prerequisites: { type: :array, items: { type: :string } } } }]
        run_test!
      end
    end
  end
  path '/admin/tool_checkouts/{id}' do
    parameter name: :id, in: :path, type: :string
    delete 'Revoke a checkout' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['revocation_reason'], properties: { revocation_reason: { type: :string } } }
      let(:id) { checkout.id.to_s }
      let(:body) { { revocation_reason: 'Retraining required' } }
      response('200', 'Revoked checkout') { schema '$ref' => '#/components/schemas/ToolCheckout'; run_test! }
    end
  end
  path '/tool_checkout_requests' do
    post 'Request tool checkout training' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['tool_id'], properties: { tool_id: { type: :string }, note: { type: :string } } }
      let(:body) { { tool_id: tool.id.to_s, note: 'Training please' } }
      response('200', 'Created request') { schema '$ref' => '#/components/schemas/ToolCheckoutRequest'; run_test! }
    end
  end
  path '/tool_checkout_requests/{id}' do
    parameter name: :id, in: :path, type: :string
    %i[put patch].each do |verb|
      public_send(verb, 'Edit own open checkout request note') do
        tags 'Tool checkouts'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { type: :object, properties: { note: { type: :string } } }
        let(:id) { request_record.id.to_s }
        let(:body) { { note: 'Updated note' } }
        response('200', 'Updated request') { schema '$ref' => '#/components/schemas/ToolCheckoutRequest'; run_test! }
      end
    end
  end
end
