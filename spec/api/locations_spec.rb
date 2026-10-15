require 'swagger_helper'

RSpec.describe 'Location contracts', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:other_shop) { create(:shop) }
  let(:location) { create(:location, shop: shop, name: 'Cabinet 1') }
  before { sign_in member; allow(REDIS).to receive(:set).and_return(true) }

  path '/locations' do
    get 'List locations for every member, optionally scoped to a set of shops' do
      tags 'Locations'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :shop_ids, in: :query, type: :array, items: { type: :string }, required: false
      response('200', 'Locations, visible to a plain member (not just admin/board/shop manager)') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Location' }
        let(:member) { create(:member, :current) }
        before { location }
        run_test! { |r| expect(JSON.parse(r.body).map { |l| l['id'] }).to eq([location.id.to_s]) }
      end
    end
  end

  path '/admin/locations' do
    get 'List locations, optionally scoped to a shop or a set of shops' do
      tags 'Locations'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :shop_id, in: :query, type: :string, required: false
      parameter name: :shop_ids, in: :query, type: :array, items: { type: :string }, required: false
      response('200', 'Locations') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Location' }
        let(:shop_id) { shop.id.to_s }
        before { location }
        run_test! { |r| expect(JSON.parse(r.body).map { |l| l['id'] }).to eq([location.id.to_s]) }
      end
    end
    post 'Create a location (admin/board or shop manager)' do
      tags 'Locations'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/LocationWrite' }
      let(:body) { { name: 'Cabinet 2', shop_id: shop.id.to_s, kind: 'cabinet' } }
      response('200', 'Created location') { schema '$ref' => '#/components/schemas/Location'; run_test! }
      response('403', 'Not a manager of this shop') do
        let(:member) { create(:member, :current) }
        run_test!
      end
      response('200', 'Created location on a specific floor with a marker icon') do
        schema '$ref' => '#/components/schemas/Location'
        let(:body) { { name: 'Fire extinguisher', shop_id: shop.id.to_s, floor_name: '2', icon: 'saw', x_pct: 20, y_pct: 30 } }
        run_test! { |r| expect(JSON.parse(r.body).slice('floorName', 'icon')).to eq('floorName' => '2', 'icon' => 'saw') }
      end
      response('200', 'A location with no floor reports its shop\'s floor') do
        schema '$ref' => '#/components/schemas/Location'
        run_test! { |r| expect(JSON.parse(r.body)['floorName']).to eq(shop.floor_name) }
      end
      response('422', 'Unknown floor') do
        let(:body) { { name: 'Nowhere', shop_id: shop.id.to_s, floor_name: '7' } }
        run_test!
      end
      response('200', 'Created location with a drawn shape') do
        schema '$ref' => '#/components/schemas/Location'
        let(:body) do
          { name: 'Woodshop', shop_id: shop.id.to_s, kind: 'area',
            shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }, { x: 30, y: 40 }] }
        end
        run_test! { |r| expect(JSON.parse(r.body)['shapePoints'].size).to eq(3) }
      end
      response('422', 'A shape needs at least 3 points') do
        let(:body) do
          { name: 'Woodshop', shop_id: shop.id.to_s, shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }] }
        end
        run_test!
      end
    end
  end

  path '/admin/locations/{id}' do
    parameter name: :id, in: :path, type: :string
    let(:id) { location.id.to_s }

    %i[put patch].each do |verb|
      public_send(verb, 'Update a location (admin/board or shop manager)') do
        tags 'Locations'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/LocationWrite' }
        let(:body) { { name: 'Renamed cabinet', shop_id: shop.id.to_s } }
        response('200', 'Updated location') { schema '$ref' => '#/components/schemas/Location'; run_test! }
        response('200', 'Reassigned to a different shop (fixing a misplaced location)') do
          schema '$ref' => '#/components/schemas/Location'
          let(:body) { { name: location.name, shop_id: other_shop.id.to_s } }
          run_test! { |r| expect(JSON.parse(r.body)['shopId']).to eq(other_shop.id.to_s) }
        end
        response('422', 'Re-parenting to a descendant is rejected') do
          let(:child) { create(:location, shop: shop, name: 'Shelf 1', parent_id: location.id) }
          let(:body) { { name: location.name, shop_id: shop.id.to_s, parent_id: child.id.to_s } }
          before { child }
          run_test!
        end
      end
    end

    delete 'Delete a location (admin/board or shop manager)' do
      tags 'Locations'
      security [sessionAuth: []]
      response('204', 'Deleted') { run_test! }
    end
  end

  describe 'DELETE /api/admin/locations/{id} cascades to nested children and their tools' do
    it 'deletes every descendant at any depth and clears location_id on tools placed anywhere in the subtree' do
      cabinet = create(:location, shop: shop, name: 'Cabinet', parent_id: location.id)
      shelf = create(:location, shop: shop, name: 'Shelf', parent_id: cabinet.id)
      top_level_tool = create(:tool, shop: shop, name: 'Drill', location_id: location.id)
      nested_tool = create(:tool, shop: shop, name: 'Caliper', location_id: shelf.id)

      delete "/api/admin/locations/#{location.id}"

      expect(response).to have_http_status(:no_content)
      expect(Location.where(id: [location.id, cabinet.id, shelf.id]).count).to eq(0)
      expect(top_level_tool.reload.location_id).to be_nil
      expect(nested_tool.reload.location_id).to be_nil
    end
  end

  describe 'DELETE /api/admin/locations/{id} clears location_id on tools placed there' do
    it "doesn't leave a tool's location_id dangling at the deleted location's id" do
      tool = create(:tool, shop: shop, name: 'Drill', location_id: location.id)

      delete "/api/admin/locations/#{location.id}"

      expect(response).to have_http_status(:no_content)
      expect(tool.reload.location_id).to be_nil
    end
  end

  # Plain request spec, not an rswag contract example -- rswag's query-string
  # builder doesn't reliably round-trip an array `let` value for an
  # `in: :query, type: :array` parameter (confirmed: the request it built
  # didn't parse server-side as an array at all). The endpoint and its
  # shop_ids param are already documented via the `parameter` declaration
  # above; this just exercises the actual behavior directly.
  describe 'GET /api/admin/locations?shop_ids[]=...' do
    it 'returns locations across every requested shop' do
      location
      other_location = create(:location, shop: other_shop, name: 'Cabinet 2')

      get '/api/admin/locations', params: { shop_ids: [shop.id.to_s, other_shop.id.to_s] }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |l| l['id'] }).to contain_exactly(location.id.to_s, other_location.id.to_s)
    end
  end

  describe 'GET /api/locations?shop_ids[]=...' do
    it 'returns locations across every requested shop for a plain member' do
      sign_in create(:member, :current)
      location
      other_location = create(:location, shop: other_shop, name: 'Cabinet 2')

      get '/api/locations', params: { shop_ids: [shop.id.to_s, other_shop.id.to_s] }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |l| l['id'] }).to contain_exactly(location.id.to_s, other_location.id.to_s)
    end
  end

  describe 'Location#tool_names in the serialized response' do
    it "lists every tool whose location_id points at this location, with tool_ids index-aligned to tool_names" do
      drill = create(:tool, shop: shop, name: 'Drill', location_id: location.id)
      caliper = create(:tool, shop: shop, name: 'Caliper', location_id: location.id)
      create(:tool, shop: shop, name: 'Unrelated Tool')

      get '/api/admin/locations', params: { shop_id: shop.id.to_s }

      body = JSON.parse(response.body).find { |l| l['id'] == location.id.to_s }
      expect(body['toolNames']).to contain_exactly('Drill', 'Caliper')
      expect(body['toolIds']).to contain_exactly(drill.id.to_s, caliper.id.to_s)
      name_by_id = body['toolIds'].zip(body['toolNames']).to_h
      expect(name_by_id[drill.id.to_s]).to eq('Drill')
      expect(name_by_id[caliper.id.to_s]).to eq('Caliper')
    end
  end
end
