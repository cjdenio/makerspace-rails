require 'swagger_helper'

RSpec.describe 'Checkout Required sheet API', type: :request do
  %w[shops tools].each do |collection|
    path "/#{collection}/{id}/checkout_required_sheet" do
      post 'Generate a printable Letter landscape Checkout Required SVG sheet' do
        tags 'Checkout sheets'
        security [sessionAuth: []]
        consumes 'application/json'
        # Error bodies are JSON; the successful response declares SVG content below.
        produces 'application/json'
        description 'Admin/Board can generate sheets for any visible resource; RMs for assigned shops and their tools; eligible checkout approvers for their permitted physical tools. Hidden resources and open tools cannot be printed. Normal session, TOTP, and CSRF checks apply.'
        parameter name: :id, in: :path, required: true, schema: { type: :string }
        parameter name: :body, in: :body, required: false, schema: {
          type: :object, properties: { copies: { type: :integer, enum: [1, 2], default: 2 } }
        }
        let(:shop) { create(:shop) }
        let(:resource) { collection == 'shops' ? shop : create(:tool, shop: shop) }
        let(:id) { resource.id.to_s }
        let(:body) { { copies: 2 } }
        let(:actor) { create(:member, :current, :admin) }
        before do
          sign_in actor
          allow(ShortUrl).to receive(:base_url).and_return('https://members.example.org')
          allow(ShortUrl).to receive(:allocate).and_return(short_url: 'HTTPS://MEMBERS.EXAMPLE.ORG/L23456789AB')
        end

        response '200', 'Standalone SVG attachment; two signs by default, one centered sign with copies=1' do
          # Document the binary response without asking rswag's JSON-only body
          # validator to parse SVG; the executable assertions below parse XML.
          metadata[:response][:content] = { 'image/svg+xml' => { schema: { type: :string, format: :binary } } }
          header 'Content-Type', schema: { type: :string }
          header 'Content-Disposition', schema: { type: :string }
          header 'Cache-Control', schema: { type: :string, enum: ['private, no-store'] }
          header 'X-Checkout-Sheet-Warning', required: false, schema: { type: :string, enum: ['missing_shop_channel'] }
          run_test! do |response|
            expect(response.media_type).to eq('image/svg+xml')
            expect(Nokogiri::XML(response.body) { |config| config.strict.nonet }.root['width']).to eq('11in')
          end
        end
        response '401', 'Authentication or CSRF required' do
          schema type: :object, properties: { error: { type: :string } }
          before { sign_out actor }
          run_test!
        end
        response '403', 'Resource is outside the viewer’s authority' do
          schema type: :object, properties: { error: { type: :string }, message: { type: :string } }
          before { actor.update!(role: 'member') }
          run_test!
        end
        response '404', 'Missing or hidden resource (including a hidden parent shop), checked before resource authority' do
          schema type: :object, required: ['error'], properties: { error: { type: :string } }
          before do
            actor.update!(role: 'member')
            resource.set(disabled: true)
          end
          run_test!
        end
        response '422', 'Invalid copies, or a tool that does not require checkout' do
          schema type: :object, required: ['error'], properties: { error: { type: :string } }
          let(:body) { { copies: 3 } }
          run_test!
        end
        response '503', 'Shortcode origin or storage unavailable; no full-URL fallback' do
          schema type: :object, required: ['error'], properties: { error: { type: :string } }
          before { allow(ShortUrl).to receive(:allocate).and_raise(ShortUrl::Unavailable) }
          run_test!
        end
      end
    end
  end
end
