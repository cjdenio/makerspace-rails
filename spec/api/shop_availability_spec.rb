require 'swagger_helper'

RSpec.describe 'Shop availability', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:id) { shop.id.to_s }
  before do
    sign_in member
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'omits unavailable shops and their tools from the reservation catalog' do
    shop.update!(reservable: true, out_of_service: true, out_of_service_note: 'Leak')
    tool = create(:tool, shop: shop, reservable: true)
    get '/api/reservation_catalog'
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['shops'].map { |item| item['id'] }).not_to include(shop.id.to_s)
    expect(response.parsed_body['tools'].map { |item| item['id'] }).not_to include(tool.id.to_s)
  end
  path '/workshops' do
    get 'List workshops including shop outage status and reason' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response '200', 'Workshops with availability and member capabilities' do
        schema type: :object, properties: {
          canAddShop: { type: :boolean }, workshops: { type: :array, items: {
            type: :object, required: %w[id outOfService outOfServiceNote reservationsAvailable tools], properties: {
              id: { type: :string }, outOfService: { type: :boolean },
              canGenerateCheckoutRequiredSheet: { type: :boolean },
              outOfServiceNote: { type: :string, nullable: true }, reservationsAvailable: { type: :boolean },
              tools: { type: :array, items: { type: :object, required: %w[id name outOfService], properties: {
                id: { type: :string }, name: { type: :string }, outOfService: { type: :boolean },
                canGenerateCheckoutRequiredSheet: { type: :boolean },
                locationName: { type: :string, nullable: true }
              } } }
            }
          } }
        }
        let!(:unavailable_tool) { create(:tool, shop: shop, out_of_service: true) }
        let!(:location) { create(:location, shop: shop, name: 'Top Shelf') }
        let!(:placed_tool) { create(:tool, shop: shop, location_id: location.id) }
        before { shop.update!(out_of_service: true, out_of_service_note: 'Leak') }
        run_test! do |response|
          data = response.parsed_body['workshops'].find { |item| item['id'] == shop.id.to_s }
          expect(data['tools']).to include(hash_including('id' => unavailable_tool.id.to_s, 'outOfService' => true))
          expect(data['tools']).to include(hash_including('id' => placed_tool.id.to_s, 'locationName' => 'Top Shelf'))
          expect(data).to include('outOfService' => true, 'outOfServiceNote' => 'Leak', 'reservationsAvailable' => false)
          expect(data['canGenerateCheckoutRequiredSheet']).to be(true)
          expect(data['tools']).to all(include('canGenerateCheckoutRequiredSheet' => true))
        end
      end
    end
  end
  path '/shops/{id}/outage' do
    parameter name: :id, in: :path, type: :string
    post 'Admin, board or assigned Resource Manager: change shop availability' do
      tags 'Shops'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      description 'The same admin, board or assigned RM may set or clear the flag. Requires a nonblank note when marking out of service. Blocks new shop and tool reservations; existing bookings remain. Queues a Slack channel announcement, saves ts_oos, and DMs linked shop resource managers with actor, shop and note. Clearing preserves tool flags and queues a back-in-service reply to ts_oos with reply_broadcast true.'
      parameter name: :body, in: :body, schema: {
        type: :object, required: ['out_of_service'], properties: {
          out_of_service: { type: :boolean }, note: { type: :string, description: 'Required and nonblank when out_of_service is true' }
        }
      }
      let(:body) { { out_of_service: true, note: 'Water leak' } }
      response '200', 'Availability saved; Slack delivery queued if configured' do
        schema type: :object, required: %w[outOfService outOfServiceNote], properties: {
          outOfService: { type: :boolean }, outOfServiceNote: { type: :string, nullable: true }
        }
        run_test!
      end
      response '403', 'Not admin, board or assigned RM' do
        let(:member) { create(:member, :current) }
        run_test!
      end
      response '422', 'Missing reason or invalid boolean' do
        let(:body) { { out_of_service: true, note: '  ' } }
        run_test!
      end
      response '404', 'Shop not found' do
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
    end
  end
end
