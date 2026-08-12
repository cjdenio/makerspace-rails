require 'rails_helper'

RSpec.describe 'Tool Checkouts API', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop') }
  let(:tool) { Tool.create!(name: 'Disabled Bandsaw', shop: shop, disabled: true) }
  let(:member) { create(:member, :current) }
  let(:resource_manager) do
    create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
  end

  before do
    allow(REDIS).to receive(:set)
    sign_in resource_manager
  end

  describe 'POST /api/admin/tool_checkouts' do
    it 'allows resource managers to check out members on disabled tools' do
      post '/api/admin/tool_checkouts', params: {
        member_id: member.id.to_s,
        tool_id: tool.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil)).to exist
      audit_log = AuditLog.where(
        event_type: 'tool_checkout_created',
        subject_id: member.id
      ).last
      expect(audit_log.slack_message).to include(
        'shop: Woodshop',
        'tool: Disabled Bandsaw'
      )
    end

    it 'allows pending members to receive a checkout for an enabled onboarding tool' do
      pending_member = create(:member, :current, status: 'pending')
      orientation = Tool.create!(
        name: 'Orientation',
        shop: shop,
        allow_pending: true
      )

      post '/api/admin/tool_checkouts', params: {
        member_id: pending_member.id.to_s,
        tool_id: orientation.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: pending_member.id, tool_id: orientation.id, revoked_at: nil)).to exist
    end

    it 'allows staff to issue an ordinary tool checkout to a pending member' do
      pending_member = create(:member, :current, status: 'pending')
      ordinary_tool = Tool.create!(name: 'Table Saw', shop: shop)

      post '/api/admin/tool_checkouts', params: {
        member_id: pending_member.id.to_s,
        tool_id: ordinary_tool.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: pending_member.id, tool_id: ordinary_tool.id, revoked_at: nil)).to exist
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
