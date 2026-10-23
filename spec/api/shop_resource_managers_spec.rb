require 'swagger_helper'

RSpec.describe 'Shop Resource Manager assignments', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: []) }
  let(:shop) { create(:shop) }
  before do
    ActiveJob::Base.queue_adapter = :test
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
  end
  path '/admin/shops/resource_manager_options' do
    get 'List Resource Managers, Admins and Board members for shop assignment (admin/board only)' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response '200', 'Resource Manager choices' do
        schema type: :array, items: { '$ref' => '#/components/schemas/FixPerson' }
        before { manager }
        run_test! { |r| expect(JSON.parse(r.body).map { |m| m['id'] }).to include(manager.id.to_s) }
      end
      response '403', 'Only admin or board may assign Resource Managers' do
        let(:member) { manager }
        run_test!
      end
    end
  end
  path '/shops' do
    get 'List visible shops including Resource Managers' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Visible shops') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Shop' }
        before { shop }
        run_test!
      end
    end
  end
  path '/admin/shops' do
    get 'List managed shops including current Resource Managers' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Managed shops') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Shop' }
        before { shop }
        run_test!
      end
    end
    post 'Create shop with optional Resource Manager assignments (admin/board)' do
      tags 'Shops'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ShopWrite' }
      let(:body) { { name: 'New workshop', resource_manager_ids: [manager.id.to_s] } }
      response('200', 'Created shop') do
        schema '$ref' => '#/components/schemas/Shop'
        run_test! do |r|
          data = JSON.parse(r.body)
          expect(manager.reload.resource_manager_shop_ids).to include(data['id'])
          expect(data['resourceManagers'].map { |m| m['id'] }).to eq([manager.id.to_s])
        end
      end
    end
  end
  path '/admin/shops/{id}' do
    parameter name: :id, in: :path, type: :string
    %i[put patch].each do |verb|
      public_send(verb, 'Update shop; only admin/board may replace Resource Managers') do
        tags 'Shops'
        description 'Changed Resource Manager assignments enqueue Slack canvas access synchronization for each added or removed member.'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ShopWrite' }
        let(:id) { shop.id.to_s }
        let(:body) { { resource_manager_ids: [manager.id.to_s] } }
        response('200', 'Updated shop') do
          schema '$ref' => '#/components/schemas/Shop'
          let(:member) { create(:member, :board_member, :current) }
          run_test! do
            expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
            expect(AuditLog.where(resource_id: shop.id, event_type: 'shop_resource_managers_changed')).to exist
          end
        end
        response('422', 'Resource Manager IDs must be valid and belong to permitted roles') do
          schema '$ref' => '#/components/schemas/FixError'
          let(:body) { { resource_manager_ids: ['invalid-id'] } }
          run_test!
          context 'member outside the permitted roles' do
            let(:body) { { resource_manager_ids: [create(:member, :current).id.to_s] } }
            run_test!
          end
        end
        response('403', 'Resource Managers cannot change their own assignments') do
          let(:member) { manager }
          before { manager.update!(resource_manager_shop_ids: [shop.id.to_s]) }
          run_test!
        end
      end
    end
  end

  it 'synchronizes canvas access only for added and removed managers' do
    other_shop = create(:shop)
    removed = create(:member, :board_member, :current, resource_manager_shop_ids: [shop.id.to_s, other_shop.id.to_s])
    retained = create(:member, :admin, :current, resource_manager_shop_ids: [shop.id.to_s])
    manager
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [manager.id.to_s, retained.id.to_s, manager.id.to_s] }, as: :json
    expect(response).to have_http_status(:ok)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ReservationSlackCanvasMemberAccessJob }
    expect(jobs.map { |job| job[:args] }).to contain_exactly(
      [manager.id.to_s, [shop.id.to_s]], [removed.id.to_s, [shop.id.to_s]]
    )
    expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
    expect(removed.reload.resource_manager_shop_ids).to eq([other_shop.id.to_s])

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [retained.id.to_s, manager.id.to_s] }, as: :json
    expect(response).to have_http_status(:ok)
    put "/api/admin/shops/#{shop.id}", params: { name: 'Renamed shop' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ReservationSlackCanvasMemberAccessJob }).to be_empty
  end

  it 'removes only this shop, preserves other shops, and leaves assignments alone when omitted' do
    other = create(:shop)
    manager.update!(resource_manager_shop_ids: [shop.id.to_s, other.id.to_s])
    put "/api/admin/shops/#{shop.id}", params: { name: 'Renamed' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(manager.reload.resource_manager_shop_ids).to eq([other.id.to_s])
  end
  it 'assigns and removes Admin and Board members without changing their roles' do
    board = create(:member, :board_member, :current)
    get '/api/admin/shops/resource_manager_options'
    expect(JSON.parse(response.body).map { |row| row['id'] }).to include(member.id.to_s, board.id.to_s)
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [member.id.to_s, board.id.to_s] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['resourceManagers'].map { |row| row['id'] }).to contain_exactly(member.id.to_s, board.id.to_s)
    expect(member.reload.role).to eq('admin')
    expect(board.reload.role).to eq('board_member')
    put "/api/admin/members/#{board.id}", params: { role: 'board_member' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(board.reload.resource_manager_shop_ids).to include(shop.id.to_s)
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(board.reload.resource_manager_shop_ids).not_to include(shop.id.to_s)
    put "/api/admin/members/#{board.id}", params: { role: 'board_member' }, as: :json
    expect(response).to have_http_status(:ok)
  end
  it 'rejects ordinary member selections before changing the shop' do
    ordinary = create(:member, :current)
    put "/api/admin/shops/#{shop.id}", params: { name: 'Invalid edit', resource_manager_ids: [ordinary.id.to_s] }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(shop.reload.name).not_to eq('Invalid edit')
  end
  it 'finishes all replacements even when a canvas enqueue raises' do
    removed = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    added = create(:member, :resource_manager, :current, resource_manager_shop_ids: [])
    allow(ReservationSlackCanvasMemberAccessJob).to receive(:perform_later) do
      expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
      expect(added.reload.resource_manager_shop_ids).to include(shop.id.to_s)
      expect(removed.reload.resource_manager_shop_ids).not_to include(shop.id.to_s)
      raise 'Queue unavailable'
    end
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [manager.id.to_s, added.id.to_s] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(ReservationSlackCanvasMemberAccessJob).to have_received(:perform_later).exactly(3).times
  end

  it 'successfully creates and assigns a shop when canvas enqueues fail' do
    allow(ReservationSlackCanvasMemberAccessJob).to receive(:perform_later).and_raise('Queue unavailable')
    post '/api/admin/shops', params: { name: 'Queue failure shop', resource_manager_ids: [manager.id.to_s] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(manager.reload.resource_manager_shop_ids).to include(response.parsed_body['id'])
  end

end
