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

  describe 'GET /api/tools' do
    before { sign_in member }

    it 'returns only non-disabled tools without operational fields' do
      get '/api/tools'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |tool| tool['name'] }).to eq(['Bandsaw'])
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
      expect(JSON.parse(response.body).map { |tool| tool['name'] }).to eq(['Bandsaw'])
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
  end
end
