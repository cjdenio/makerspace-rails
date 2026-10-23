require 'swagger_helper'

RSpec.describe 'Checkout expiration API', type: :request do
  let(:actor) { create(:member, :admin, :current) }
  let(:tool) { create(:tool) }
  let(:checkout) { create(:tool_checkout, tool: tool) }
  before do
    sign_in actor
    lock_tokens = {}
    allow(REDIS).to receive(:set) { |key, token, **_options| lock_tokens[key] = token; true }
    allow(REDIS).to receive(:get).and_call_original
    allow(REDIS).to receive(:get).with(%r{^checkout_request_lock/}) { |key| lock_tokens[key] }
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  path '/admin/tool_checkouts/{id}/expiration' do
    patch 'Change a current checkout expiration (admin, board or owning-shop RM)' do
      tags 'Tool checkouts'
      operationId 'updateCheckoutExpiration'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, required: true
      parameter name: :body, in: :body, schema: {
        type: :object, required: %w[expires_on expiration_revision], properties: {
          expires_on: { type: :string, format: :date, nullable: true, description: 'Valid through this Eastern calendar date; null means Never.' },
          expiration_revision: { type: :integer, minimum: 0 }
        }
      }
      let(:id) { checkout.id.to_s }
      let(:body) { { expires_on: (Date.current + 30).iso8601, expiration_revision: 0 } }
      response '200', 'Updated checkout' do
        schema '$ref' => '#/components/schemas/ToolCheckout'
        # Each leaf context submits once; a parent run_test! adds an inherited
        # submission hook and would make child PATCH requests stale.
        context 'admin manager' do
          run_test!(requires_transactions: true) { expect(checkout.reload.expiration_revision).to eq(1) }
        end
        context 'board manager' do
          let(:actor) { create(:member, :board_member, :current) }
          run_test!(requires_transactions: true) { expect(checkout.reload.expiration_revision).to eq(1) }
        end
        context 'owning shop Resource Manager' do
          let(:actor) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [tool.shop_id.to_s]) }
          run_test!(requires_transactions: true) { expect(checkout.reload.expiration_revision).to eq(1) }
        end
        context 'clear expiration' do
          let(:checkout) { create(:tool_checkout, tool: tool, expires_on: Date.current + 10) }
          let(:body) { { expires_on: nil, expiration_revision: 0 } }
          run_test!(requires_transactions: true) do
            expect(checkout.reload.expires_on).to be_nil
            expect(checkout.expiration_revision).to eq(1)
          end
        end
      end
      response '403', 'Not a manager of this tool' do
        let(:actor) { create(:member, :current) }
        context 'ordinary member' do
          run_test!
        end
        context 'ordinary checkout approver' do
          before { create(:checkout_approver, member: actor, tool_ids: [tool.id.to_s]) }
          run_test!
        end
        context 'Resource Manager outside the shop' do
          let(:actor) { create(:member, :resource_manager, :current) }
          run_test!
        end
      end
      response '401', 'Authentication required' do
        before { sign_out actor }
        run_test!
      end
      response '404', 'Checkout not found' do
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
      response '409', 'Stale revision or historical checkout' do
        let(:body) { { expires_on: nil, expiration_revision: 99 } }
        run_test!
      end
      response '422', 'Invalid expiration' do
        let(:body) { { expires_on: '2026-02-30', expiration_revision: 0 } }
        run_test!
      end
    end
  end

  path '/admin/tools/{id}/checkout_expirations' do
    post 'Set a future expiration on every current non-revoked checkout for a tool' do
      tags 'Tool checkouts'
      operationId 'bulkUpdateCheckoutExpirations'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, required: true
      parameter name: :body, in: :body, schema: {
        type: :object, required: ['expires_on'], properties: {
          expires_on: { type: :string, format: :date, description: 'Strictly later than today in America/New_York.' }
        }
      }
      let(:id) { tool.id.to_s }
      let(:body) { { expires_on: (Date.current + 30).iso8601 } }
      response '200', 'Updated count, excluding revoked and superseded history' do
        schema type: :object, required: ['affectedCount'], properties: { affectedCount: { type: :integer } }
        before { checkout }
        run_test!(requires_transactions: true) { |response| expect(JSON.parse(response.body)['affectedCount']).to eq(1) }
      end
      response '403', 'Not a manager of this tool' do
        let(:actor) { create(:member, :current) }
        run_test!
      end
      response '401', 'Authentication required' do
        before { sign_out actor }
        run_test!
      end
      response '404', 'Tool not found' do
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
      response '422', 'A future date is required' do
        let(:body) { { expires_on: (Date.current - 2).iso8601 } }
        run_test!
      end
    end
  end

  path '/admin/system_configs/run_job' do
    post 'Run a registered portal job; checkout expiration notices require an admin' do
      tags 'System configuration'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object, required: ['key'], properties: { key: { type: :string, enum: SystemConfig::JOB_KEYS.keys } }
      }
      let(:body) { { key: 'checkout_expiration_notice' } }
      response '200', 'Job queued' do
        before { allow(CheckoutExpirationNoticeJob).to receive(:perform_later) }
        run_test! { expect(CheckoutExpirationNoticeJob).to have_received(:perform_later) }
      end
      response '403', 'Checkout expiration notices are admin-only' do
        let(:actor) { create(:member, :board_member, :current) }
        run_test!
      end
      response '401', 'Authentication required' do
        before { sign_out actor }
        run_test!
      end
      response '422', 'Unknown job' do
        let(:body) { { key: 'unknown' } }
        run_test!
      end
    end
  end

  describe 'expiration notice administration' do
    it 'permits admin execution and rejects board execution' do
      expect(CheckoutExpirationNoticeJob).to receive(:perform_later).once
      post '/api/admin/system_configs/run_job', params: { key: 'checkout_expiration_notice' }
      expect(response).to have_http_status(:ok)
      sign_in create(:member, :board_member, :current)
      post '/api/admin/system_configs/run_job', params: { key: 'checkout_expiration_notice' }
      expect(response).to have_http_status(:forbidden)
    end

    it 'validates notice days and retains the default' do
      %w[3 0 -1 4.5 text].each do |value|
        put '/api/admin/system_configs/update_setting', params: { key: 'checkout_expiration_notice_days', value: value }
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(CheckoutExpirationNotice.advance_days).to eq(14)
      put '/api/admin/system_configs/update_setting', params: { key: 'checkout_expiration_notice_days', value: '21' }
      expect(response).to have_http_status(:ok)
      expect(CheckoutExpirationNotice.advance_days).to eq(21)
    end
  end
end
