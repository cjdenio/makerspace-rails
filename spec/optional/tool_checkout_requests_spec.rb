require 'rails_helper'

if ENV['RUN_OPTIONAL_TOOL_CHECKOUT_SPECS'] == 'true'
  RSpec.describe 'Tool checkout requests', type: :request do
    let(:member) { create(:member, :current) }
    let(:shop) { Shop.create!(name: 'Woodshop') }
    let(:prerequisite) { Tool.create!(name: 'Safety', shop: shop) }
    let(:tool) { Tool.create!(name: 'Bandsaw', shop: shop, prerequisite_ids: [prerequisite.id]) }

    before { sign_in member }

    it 'lists available non-disabled tools with unmet prerequisites' do
      get '/api/tools'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      bandsaw = body.find { |entry| entry['id'] == tool.id.as_json }
      expect(bandsaw['unmetPrerequisiteNames']).to include('Safety')
      expect(bandsaw['requestable']).to eq(false)
    end

    it 'allows a valid member to request a tool after prerequisites are met' do
      ToolCheckout.create!(member: member, tool: prerequisite)

      post '/api/tool_checkout_requests', params: { tool_id: tool.id, note: 'Please check me out' }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: 'open')).to exist
    end

    it 'closes an open request when a checkout is granted' do
      request = ToolCheckoutRequest.create!(member: member, tool: tool)

      checkout = ToolCheckout.create!(member: member, tool: tool)

      expect(request.reload.status).to eq('closed')
      expect(request.checked_out_id).to eq(checkout.id)
    end
  end
end
