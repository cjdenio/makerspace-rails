require 'rails_helper'

RSpec.describe 'Tools API', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop') }
  let(:member) { create(:member, :current) }
  let!(:visible_tool) do
    Tool.create!(
      name: 'Bandsaw',
      description: 'Cuts wood',
      shop: shop,
      disabled: false,
      announce: true,
      announce_channel: 'woodshop',
      users_channel: 'bandsaw-users'
    )
  end
  let!(:disabled_tool) { Tool.create!(name: 'Hidden Lathe', shop: shop, disabled: true) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
  end

  describe 'GET /api/tools' do
    before { sign_in member }

    it 'returns only non-disabled tools without operational fields' do
      get '/api/tools'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |tool| tool['name'] }).to eq(['Bandsaw'])
      expect(body.first['allowPending']).to be(false)
      expect(body.first).not_to have_key('announceChannel')
      expect(body.first).not_to have_key('usersChannel')
      expect(body.first).not_to have_key('announce')
    end
  end

  describe 'GET /api/admin/tools' do
    it 'returns 403 for a regular member who is not a checkout approver' do
      sign_in member

      get '/api/admin/tools'

      expect(response).to have_http_status(:forbidden)
    end

    it 'returns the tool list for an admin' do
      sign_in create(:member, :admin, :current)

      get '/api/admin/tools'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |tool| tool['name'] }).to include('Bandsaw', 'Hidden Lathe')
    end

    it 'returns the non-disabled tool list for a checkout approver' do
      approver = create(:member, :current)
      CheckoutApprover.create!(member: approver, shop_ids: [shop.id])
      sign_in approver

      get '/api/admin/tools'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |tool| tool['name'] }).to eq(['Bandsaw'])
      expect(body.first).not_to have_key('reservationRequiresApproval')
      expect(body.first).not_to have_key('announceChannel')
    end

    it 'scopes checkout approver tool lists to assigned shops' do
      other_shop = Shop.create!(name: 'Metal Shop')
      Tool.create!(name: 'MIG Welder', shop: other_shop)
      approver = create(:member, :current)
      CheckoutApprover.create!(member: approver, shop_ids: [shop.id])
      sign_in approver

      get '/api/admin/tools', params: { shop_id: other_shop.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq([])
    end
  end

  describe 'POST /api/admin/shops' do
    before { sign_in create(:member, :admin, :current) }

    it 'normalizes Slack names and stores Wiki and GDrive fields' do
      post '/api/admin/shops', params: {
        name: 'Documentation Shop',
        slack_channel: '#shop-docs',
        wiki_url: 'https://wiki.example.test/docs',
        gdrive_id: 'folder-shop'
      }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include(
        'slackChannel' => 'shop-docs',
        'wikiUrl' => 'https://wiki.example.test/docs',
        'gdriveId' => 'folder-shop'
      )
    end

    it 'rejects a shop whose name differs only by case from an existing shop' do
      post '/api/admin/shops', params: {
        name: 'woodSHOP',
        slack_channel: 'shop-woodshop-alt'
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Shop.where(name: 'woodSHOP')).not_to exist
      expect(Shop.count).to eq(1)
    end
  end

  describe 'PUT /api/admin/shops/:id' do
    before { sign_in create(:member, :admin, :current) }

    it 'stores the shop color and selected same-shop reservation prerequisites' do
      put "/api/admin/shops/#{shop.id}", params: {
        reservable: true,
        color_id: "7",
        reservation_prerequisite_tool_ids: [visible_tool.id.to_s]
      }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include(
        "colorId" => "7",
        "reservationPrerequisiteToolIds" => [visible_tool.id.to_s],
        "reservationPrerequisiteNames" => [visible_tool.name]
      )
    end
  end

  describe 'PUT /api/admin/tools/:id' do
    before { sign_in create(:member, :admin, :current) }

    it 'normalizes channel fields and stores a GDrive folder ID' do
      put "/api/admin/tools/#{visible_tool.id}", params: {
        announce_channel: '#shop-announcements',
        users_channel: '##bandsaw-users',
        gdrive_id: 'folder-tool'
      }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include(
        'announceChannel' => 'shop-announcements',
        'usersChannel' => 'bandsaw-users',
        'gdriveId' => 'folder-tool'
      )
    end
  end

  describe 'GET /api/admin/google_calendar/colors' do
    before { sign_in create(:member, :admin, :current) }

    it 'returns the complete curated Google Calendar color list' do
      colors = 35.times.map do |index|
        {
          id: (index + 1).to_s,
          name: "Color #{index + 1}",
          backgroundColor: "#000000",
          foregroundColor: "#ffffff"
        }
      end
      allow(Service::GoogleWorkspace).to receive(:calendar_colors).and_return(colors)

      get "/api/admin/google_calendar/colors"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["colors"]).to eq(colors.map(&:stringify_keys))
    end
  end

  describe 'POST /api/admin/tools' do
    before { sign_in create(:member, :admin, :current) }

    it 'rejects a tool whose name differs only by case from an existing tool in the same shop' do
      post '/api/admin/tools', params: {
        name: 'bandSAW',
        shop_id: shop.id.to_s
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Tool.where(name: 'bandSAW', shop_id: shop.id)).not_to exist
      expect(Tool.where(shop_id: shop.id).count).to eq(2)
    end

    it 'stores whether pending members may use the tool' do
      post '/api/admin/tools', params: {
        name: 'Orientation',
        shop_id: shop.id.to_s,
        allow_pending: true
      }

      expect(response).to have_http_status(:ok)
      expect(Tool.find_by(name: 'Orientation').allow_pending).to be(true)
      expect(JSON.parse(response.body)['allowPending']).to be(true)
    end

    it 'requires tool names to be unique across shops' do
      other_shop = create(:shop, name: 'Facilities')

      post '/api/admin/tools', params: {
        name: visible_tool.name,
        shop_id: other_shop.id.to_s
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Tool.where(name: visible_tool.name).count).to eq(1)
    end
  end

  describe 'PUT /api/admin/tools/:id' do
    let(:other_shop) { create(:shop, name: 'Metal Shop') }
    let(:resource_manager) do
      create(
        :member,
        :resource_manager,
        :current,
        resource_manager_shop_ids: [shop.id.to_s, other_shop.id.to_s]
      )
    end

    before { sign_in resource_manager }

    {
      current: {
        start_at: -> { 1.hour.ago },
        end_at: -> { 1.hour.from_now },
        status: "approved"
      },
      future: {
        start_at: -> { 1.day.from_now },
        end_at: -> { 1.day.from_now + 1.hour },
        status: "pending"
      }
    }.each do |timing, reservation_attributes|
      it "rejects moving a tool with a #{timing} blocking reservation" do
        reservation = create(
          :reservation,
          shop: shop,
          reservation_scope: "tools",
          tool_ids: [visible_tool.id.to_s],
          start_at: reservation_attributes[:start_at].call,
          end_at: reservation_attributes[:end_at].call,
          status: reservation_attributes[:status]
        )

        put "/api/admin/tools/#{visible_tool.id}",
          params: { shop_id: other_shop.id.to_s }

        expect(response).to have_http_status(:conflict)
        expect(visible_tool.reload.shop_id).to eq(shop.id)
        expect(reservation.reload.shop_id).to eq(shop.id)
      end
    end

    it "allows moving a tool when all blocking reservations have ended" do
      create(
        :reservation,
        shop: shop,
        reservation_scope: "tools",
        tool_ids: [visible_tool.id.to_s],
        start_at: 2.hours.ago,
        end_at: 1.hour.ago,
        status: "approved"
      )

      put "/api/admin/tools/#{visible_tool.id}",
        params: { shop_id: other_shop.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(visible_tool.reload.shop_id).to eq(other_shop.id)
    end

    it "allows moving a tool when its future reservations are cancelled" do
      create(
        :reservation,
        shop: shop,
        reservation_scope: "tools",
        tool_ids: [visible_tool.id.to_s],
        start_at: 1.day.from_now,
        end_at: 1.day.from_now + 1.hour,
        status: "cancelled"
      )

      put "/api/admin/tools/#{visible_tool.id}",
        params: { shop_id: other_shop.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(visible_tool.reload.shop_id).to eq(other_shop.id)
    end

    it "allows non-shop updates while a blocking reservation exists" do
      create(
        :reservation,
        shop: shop,
        reservation_scope: "tools",
        tool_ids: [visible_tool.id.to_s],
        start_at: 1.hour.ago,
        end_at: 1.hour.from_now,
        status: "approved"
      )

      put "/api/admin/tools/#{visible_tool.id}",
        params: { description: "Updated description" }

      expect(response).to have_http_status(:ok)
      expect(visible_tool.reload.description).to eq("Updated description")
    end
  end

  describe 'DELETE /api/admin/tools/:id' do
    let(:admin) { create(:member, :admin, :current) }

    before { sign_in admin }

    it 'identifies every checkout and reservation prerequisite reference' do
      checkout_tool = Tool.create!(
        name: 'Jointer', shop: shop, prerequisite_ids: [visible_tool.id]
      )
      reservation_tool = Tool.create!(
        name: 'Planer', shop: shop,
        reservation_prerequisite_tool_ids: [visible_tool.id.to_s]
      )
      shop.set(reservation_prerequisite_tool_ids: [visible_tool.id.to_s])
      volunteer_task = VolunteerTask.create!(
        title: 'Dust collection', description: 'Clean ducts', shop_id: shop.id,
        prerequisite_tool_ids: [visible_tool.id], created_by_id: admin.id
      )
      volunteer_event = VolunteerEvent.create!(
        title: 'Safety day', description: 'Review safety', shop_id: shop.id,
        prerequisite_tool_ids: [visible_tool.id.to_s], created_by_id: admin.id
      )

      delete "/api/admin/tools/#{visible_tool.id}"

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(
        'Jointer', 'Planer', 'Woodshop', 'Dust collection', 'Safety day'
      )
      expect(Tool.where(id: visible_tool.id)).to exist

      checkout_tool.set(prerequisite_ids: [])
      reservation_tool.set(reservation_prerequisite_tool_ids: [])
      shop.set(reservation_prerequisite_tool_ids: [])
      volunteer_task.set(prerequisite_tool_ids: [])
      volunteer_event.set(prerequisite_tool_ids: [])
      visible_tool.set(
        prerequisite_ids: [visible_tool.id],
        reservation_prerequisite_tool_ids: [visible_tool.id.to_s]
      )

      delete "/api/admin/tools/#{visible_tool.id}"

      expect(response).to have_http_status(:no_content)
      expect(Tool.where(id: visible_tool.id)).not_to exist
    end


    it 'allows a board member to force-delete a circular prerequisite and cleans references' do
      board_member = create(:member, :board_member, :current)
      sign_in board_member
      dependent = Tool.create!(name: 'Circular dependent', shop: shop)
      visible_tool.set(prerequisite_ids: [dependent.id])
      dependent.set(
        prerequisite_ids: [visible_tool.id],
        reservation_prerequisite_tool_ids: [visible_tool.id.to_s]
      )
      shop.set(reservation_prerequisite_tool_ids: [visible_tool.id])
      task = VolunteerTask.create!(
        title: 'Force cleanup task', description: 'Help out', shop_id: shop.id,
        prerequisite_tool_ids: [visible_tool.id], created_by_id: board_member.id
      )
      event = VolunteerEvent.create!(
        title: 'Force cleanup event', description: 'Help out', shop_id: shop.id,
        prerequisite_tool_ids: [visible_tool.id.to_s], created_by_id: board_member.id
      )

      delete "/api/admin/tools/#{visible_tool.id}", params: { force: true }

      expect(response).to have_http_status(:no_content)
      expect(Tool.where(id: visible_tool.id)).not_to exist
      expect(dependent.reload.prerequisite_ids).to eq([])
      expect(dependent.reservation_prerequisite_tool_ids).to eq([])
      expect(shop.reload.reservation_prerequisite_tool_ids).to eq([])
      expect(task.reload.prerequisite_tool_ids).to eq([])
      expect(event.reload.prerequisite_tool_ids).to eq([])
    end
  end

  describe 'DELETE /api/admin/shops/:id' do
    let(:admin) { create(:member, :admin, :current) }

    before { sign_in admin }

    it 'blocks surviving references but ignores references deleted with the shop' do
      internal_tool = Tool.create!(
        name: 'Internal dependent', shop: shop,
        prerequisite_ids: [visible_tool.id.to_s],
        reservation_prerequisite_tool_ids: [visible_tool.id.to_s]
      )
      shop.set(reservation_prerequisite_tool_ids: [visible_tool.id.to_s])

      surviving_shop = Shop.create!(name: 'Surviving shop')
      checkout_tool = Tool.create!(name: 'External checkout dependent', shop: surviving_shop)
      reservation_tool = Tool.create!(name: 'External reservation dependent', shop: surviving_shop)
      checkout_tool.set(prerequisite_ids: [visible_tool.id])
      reservation_tool.set(reservation_prerequisite_tool_ids: [visible_tool.id])
      surviving_shop.set(reservation_prerequisite_tool_ids: [visible_tool.id.to_s])
      volunteer_task = VolunteerTask.create!(
        title: 'External volunteer task', description: 'Help out', shop_id: shop.id,
        prerequisite_tool_ids: [visible_tool.id], created_by_id: admin.id
      )
      volunteer_event = VolunteerEvent.create!(
        title: 'External volunteer event', description: 'Help together', shop_id: shop.id,
        prerequisite_tool_ids: [disabled_tool.id.to_s], created_by_id: admin.id
      )

      delete "/api/admin/shops/#{shop.id}"

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(
        'External checkout dependent', 'External reservation dependent', 'Surviving shop',
        'External volunteer task', 'External volunteer event'
      )
      expect(response.body).not_to include('Internal dependent')
      expect(Shop.where(id: shop.id)).to exist

      checkout_tool.set(prerequisite_ids: [])
      reservation_tool.set(reservation_prerequisite_tool_ids: [])
      surviving_shop.set(reservation_prerequisite_tool_ids: [])
      volunteer_task.set(prerequisite_tool_ids: [])
      volunteer_event.set(prerequisite_tool_ids: [])

      delete "/api/admin/shops/#{shop.id}"

      expect(response).to have_http_status(:no_content)
      expect(Shop.where(id: shop.id)).not_to exist
      expect(Tool.where(id: [visible_tool.id, internal_tool.id])).not_to exist
    end
  end
end
