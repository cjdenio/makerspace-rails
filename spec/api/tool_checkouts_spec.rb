require 'rails_helper'

RSpec.describe 'Tool Checkouts API', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop') }
  let(:tool) { Tool.create!(name: 'Disabled Bandsaw', shop: shop, disabled: true) }
  let(:member) { create(:member, :current) }
  let(:resource_manager) { create(:member, :resource_manager, :current) }

  before { sign_in resource_manager }

  describe 'POST /api/admin/tool_checkouts' do
    it 'allows resource managers to check out members on disabled tools' do
      post '/api/admin/tool_checkouts', params: {
        member_id: member.id.to_s,
        tool_id: tool.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil)).to exist
    end
  end

  describe 'DELETE /api/admin/tool_checkouts/:id' do
    it 'allows resource managers to revoke checkouts for disabled tools' do
      checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: resource_manager)

      delete "/api/admin/tool_checkouts/#{checkout.id}", params: {
        revocation_reason: 'Safety retraining required'
      }

      expect(response).to have_http_status(:ok)
      expect(checkout.reload.revoked_at).to be_present
      expect(checkout.revocation_reason).to eq('Safety retraining required')
    end
  end
end
