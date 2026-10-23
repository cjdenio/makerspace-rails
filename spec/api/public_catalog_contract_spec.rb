require 'swagger_helper'

RSpec.describe 'Public catalog contracts', type: :request do
  let(:shop) { create(:shop, out_of_service: true, out_of_service_note: 'Private maintenance note') }
  let(:tool) { create(:tool, shop: shop, out_of_service: true) }
  %w[shop tool].each do |kind|
    ["/#{kind}/{id}/public", "/api/#{kind}/{id}/public", "/#{kind}s/{id}/public"].flat_map { |route| [route, "#{route}.{format}"] }.each do |route|
      path route do
        parameter name: :id, in: :path, type: :string
        get "Public #{kind} catalog (also accepts .json, .html, .svg suffixes)", operation: { servers: [{ url: '/' }] } do
          tags 'Public catalog'
          security []
          produces 'application/json'
          description 'No authentication. Singular routes default to HTML; plural aliases default to JSON. Use a .json suffix for JSON; query parameters do not override route format defaults. Hidden tools/shops return a generic 404. HTML and JSON revalidate; stable QR SVG responses retain three-day caching.'
          parameter name: :format, in: :path, required: true, schema: { type: :string, enum: %w[json html svg] } if route.include?('{format}')
          parameter name: :'If-None-Match', in: :header, required: false, schema: { type: :string }
          let(:id) { kind == 'tool' ? tool.id.to_s : shop.id.to_s }
          let(:json_route) { route.sub('{id}', id).sub('.{format}', '') + '.json' }
          response('200', 'Public projection, page, or QR SVG') do
            schema '$ref' => "#/components/schemas/PublicCatalog#{kind.capitalize}"
            header 'Cache-Control', schema: { type: :string }, description: 'JSON/HTML: public, max-age=0, s-maxage=0, must-revalidate; SVG: public, max-age=259200, s-maxage=259200'
            header 'ETag', schema: { type: :string }, description: 'Representation digest including tool availability for HTML/JSON.'
            metadata[:response][:content] = { 'text/html' => { schema: { type: :string } }, 'image/svg+xml' => { schema: { type: :string } } }
            it 'returns the public JSON projection with revalidation' do |example|
              tool
              get json_route
              assert_response_matches_metadata(example.metadata)
              data = JSON.parse(response.body)
              expect(kind == 'tool' ? data['out_of_service'] : data['tools'].first['out_of_service']).to eq(true)
              expect(kind == 'tool' ? data['shop']['out_of_service'] : data['out_of_service']).to eq(true)
              expect(data.to_json).not_to include('Private maintenance note', 'ts_oos')
              expect(response.headers['Cache-Control']).to include('max-age=0', 'must-revalidate')
              expect(data.to_json).not_to include('reporter', 'ticket_id')
            end
          end
          response('304', 'Unchanged representation for a matching ETag') do
            it 'revalidates with the matching ETag' do |example|
              get json_route
              etag = response.headers['ETag']
              get json_route, headers: { 'If-None-Match' => etag }
              assert_response_matches_metadata(example.metadata)
            end
          end
          response('404', 'Unavailable or hidden record; no-store, generic error (HTML shows public directory)') do
            it 'does not expose hidden resources' do |example|
              shop.update!(disabled: true)
              get json_route
              assert_response_matches_metadata(example.metadata)
              expect(response.headers['Cache-Control']).to eq('no-store')
            end
          end
        end
      end
    end
  end
end
