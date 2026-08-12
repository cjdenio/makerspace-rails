require 'rails_helper'

RSpec.describe 'Pending-member Safety Checkout requests', type: :request do
  let(:member) { create(:member, status: 'pending', expirationTime: nil) }
  let(:shop) { create(:shop, name: 'Facilities') }
  let!(:orientation) do
    create(:tool, name: 'Orientation', shop: shop, allow_pending: true)
  end
  let!(:ordinary_tool) do
    create(:tool, name: 'Bandsaw', shop: shop, allow_pending: false)
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    sign_in member
  end

  it 'lists and permits only tools enabled for pending members' do
    get '/api/tools'

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).map { |tool| tool['name'] }).to eq(['Orientation'])

    post '/api/tool_checkout_requests', params: { tool_id: orientation.id.to_s }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('memberStatus')).to eq('pending')
    expect(ToolCheckoutRequest.where(member: member, tool: orientation, status: 'open')).to exist
  end

  it 'rejects an ordinary tool with onboarding guidance' do
    post '/api/tool_checkout_requests', params: { tool_id: ordinary_tool.id.to_s }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['message']).to include('activated', 'Orientation')
  end
end
