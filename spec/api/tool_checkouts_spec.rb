require 'swagger_helper'

RSpec.describe 'Tool Checkouts API', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop') }
  let(:tool) { Tool.create!(name: 'Disabled Bandsaw', shop: shop, disabled: true) }
  let(:member) { create(:member, :current) }
  let(:resource_manager) do
    create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    sign_in resource_manager
  end

  describe 'POST /api/admin/tool_checkouts' do
    it 'rejects disabled tools even for resource managers' do
      post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: tool.id.to_s }
      expect(response).to have_http_status(:unprocessable_content)
      expect(ToolCheckout.count).to eq(0)
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

    it 'rejects an ordinary tool checkout for a pending member' do
      pending_member = create(:member, :current, status: 'pending')
      ordinary_tool = Tool.create!(name: 'Table Saw', shop: shop)

      post '/api/admin/tool_checkouts', params: {
        member_id: pending_member.id.to_s,
        tool_id: ordinary_tool.id.to_s
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(ToolCheckout.where(member_id: pending_member.id, tool_id: ordinary_tool.id, revoked_at: nil)).not_to exist
    end
  end

  describe 'DELETE /api/admin/tool_checkouts/:id' do
    it 'allows resource managers to revoke checkouts for disabled tools' do
      original_approver = create(
        :member,
        :resource_manager,
        :current,
        resource_manager_shop_ids: [shop.id.to_s]
      )
      SlackUser.create!(member: original_approver, slack_id: 'UORIGINAL', slack_email: original_approver.email)
      checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: original_approver)

      delete "/api/admin/tool_checkouts/#{checkout.id}", params: {
        revocation_reason: 'Safety retraining required'
      }

      expect(response).to have_http_status(:ok)
      expect(checkout.reload.revoked_at).to be_present
      expect(REDIS).to have_received(:set).with(
        "checkout_request_lock/#{member.id}/#{tool.id}", anything, nx: true, ex: 30)
      expect(checkout.revocation_reason).to eq('Safety retraining required')
      audit_log = AuditLog.where(event_type: 'tool_checkout_revoked', resource_id: checkout.id).last
      expect(audit_log.slack_message).to include('shop: Woodshop', 'tool: Disabled Bandsaw')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_including('Your approval', 'Disabled Bandsaw', 'an RM'),
        'UORIGINAL'
      )
    end

    it 'completes revocation bookkeeping when the approver DM fails' do
      checkout = ToolCheckout.create!(
        member: member,
        tool: tool,
        approved_by: create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      )
      allow_any_instance_of(ToolCheckout).to receive(:send_approver_revocation_slack_notification)
        .and_raise(StandardError, 'account_inactive')
      expect_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
      allow(Service::ErrorReporter).to receive(:notify)

      delete "/api/admin/tool_checkouts/#{checkout.id}", params: {
        revocation_reason: 'Safety retraining required'
      }

      expect(response).to have_http_status(:ok)
      expect(checkout.reload.revoked_at).to be_present
      expect(AuditLog.where(event_type: 'tool_checkout_revoked', resource_id: checkout.id)).to exist
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError),
        context: hash_including(checkout_id: checkout.id.to_s)
      )
    end
  end
end

RSpec.describe 'Admin tool checkouts API', type: :request do
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  path '/admin/tool_checkouts/{id}' do
    delete 'Revokes a tool checkout' do
      tags 'AdminToolCheckouts'
      operationId 'revokeAdminToolCheckout'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, required: true,
        description: 'Tool checkout ID'
      parameter name: :revocation_details, in: :body, schema: {
        type: :object,
        properties: {
          revocation_reason: { type: :string }
        },
        required: ['revocation_reason']
      }

      response '200', 'checkout revoked even when the best-effort approver notification fails' do
        let(:shop) { create(:shop) }
        let(:tool) { create(:tool, shop: shop) }
        let(:member) { create(:member, :current) }
        let(:resource_manager) do
          create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
        end
        let(:checkout) { create(:tool_checkout, member: member, tool: tool, approved_by: resource_manager) }
        let(:id) { checkout.id.to_s }
        let(:revocation_details) { { revocation_reason: 'Safety retraining required' } }

        before do
          sign_in resource_manager
          allow_any_instance_of(ToolCheckout).to receive(:send_revocation_slack_notification)
          allow_any_instance_of(ToolCheckout).to receive(:send_approver_revocation_slack_notification)
            .and_raise(StandardError, 'account_inactive')
          allow_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
          allow(Service::ErrorReporter).to receive(:notify)
          allow(Service::AuditLogger).to receive(:log)
        end

        schema type: :object,
          properties: {
            id: { type: :string },
            memberId: { type: :string },
            toolId: { type: :string },
            checkedOutAt: { type: :string, format: 'date-time' },
            revokedAt: { type: :string, format: 'date-time' },
            revocationReason: { type: :string },
            approvedById: { type: :string, nullable: true },
            active: { type: :boolean }
          },
          required: %w[id memberId toolId checkedOutAt revokedAt revocationReason active]

        run_test! do |response|
          expect(response).to have_http_status(:ok)
          expect(checkout.reload.revoked_at).to be_present
          expect(Service::ErrorReporter).to have_received(:notify).with(
            instance_of(StandardError),
            context: hash_including(checkout_id: checkout.id.to_s)
          )
        end
      end

      response '422', 'revocation reason is required' do
        let(:shop) { create(:shop) }
        let(:resource_manager) do
          create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
        end
        let(:id) { create(:tool_checkout, tool: create(:tool, shop: shop)).id.to_s }
        let(:revocation_details) { {} }
        before { sign_in resource_manager }

        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
end


describe "Shared checkout creation API", type: :request do
  path "/admin/tool_checkouts/lookup_card" do
    post "Looks up the member behind a tapped fob for a checkout on a tool" do
      tags "AdminToolCheckouts"
      operationId "lookupAdminToolCheckoutCard"
      description "Turns a fob UID (uppercase hexadecimal byte pairs, as read by the NFC scanner) into the member it is assigned to and whether that member can be checked out on the tool, or on the tool group when tool_group_id is given instead (exactly one of the two, otherwise 422). A fob reported lost or stolen is refused with 422 and does not identify the member. Every lookup is recorded in the audit log whatever its outcome, with the target and the end of the UID; lookups are not throttled. Nothing is created; the approver confirms and then posts the checkout. Allowed for anyone who can approve checkouts for this tool: admin or board member, the shop's resource manager, or an approver assigned to the tool or its shop. Others get 403 and no member data. The response is limited to what is needed to confirm the person (member id, name, status, expiration, eligibility, the reason when ineligible, unmet prerequisite names) and is not cacheable. An open request for the tool does not make the member ineligible. A POST keeps the UID out of URLs and logs. 404 means the fob, tool, or the card's member was not found; 409 means duplicate UID records need administrator repair."
      consumes "application/json"
      produces "application/json"
      parameter name: :lookup, in: :body, schema: {
        type: :object, properties: { tool_id: { type: :string }, tool_group_id: { type: :string, description: "Instead of tool_id, to check a member out on a tool group." }, uid: { type: :string } }, required: %w[uid]
      }
      let(:actor) { create(:member, :current, :admin) }
      let(:target) { create(:member, :current) }
      let(:tool) { create(:tool) }
      let!(:card) { create(:card, member: target, uid: "04A1B2C3") }
      let(:lookup) { { tool_id: tool.id.to_s, uid: "04A1B2C3" } }
      before { sign_in actor }

      response "200", "member behind the fob" do
        schema type: :object, required: %w[memberId name status eligible],
          properties: {
            memberId: { type: :string }, name: { type: :string }, status: { type: :string },
            expirationTime: { type: :integer, nullable: true }, eligible: { type: :boolean },
            error: { type: :string, nullable: true },
            unmetPrerequisites: { type: :array, items: { type: :string } }
          }
        run_test! do |response|
          expect(JSON.parse(response.body)).to include("memberId" => target.id.to_s, "eligible" => true)
        end
      end
      response "403", "current actor cannot approve this tool" do
        let(:actor) { create(:member, :current) }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "404", "unknown fob, tool or card without a member" do
        let(:lookup) { { tool_id: tool.id.to_s, uid: "AABBCCDD" } }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "422", "UID is not uppercase hexadecimal byte pairs" do
        let(:lookup) { { tool_id: tool.id.to_s, uid: "not-a-uid" } }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end

  path "/admin/tool_checkouts" do
    post "Approves a safety checkout under the member/tool lock" do
      tags "AdminToolCheckouts"
      operationId "createAdminToolCheckout"
      description "Rechecks the actor's current membership and admin/board, managed-shop or assigned-tool authority inside the shared member/tool lock. The target must be active and unexpired, or pending on a tool allowing pending members. The tool and shop must be enabled, require a checkout, and all prerequisites must be satisfied. Existing checkout records, unavailable resources and lock contention are rejected. The model callback closes an open request and preserves notifications, users-channel invitations and audit logging."
      consumes "application/json"
      produces "application/json"
      parameter name: :checkout_details, in: :body, schema: {
        type: :object, properties: { member_id: { type: :string }, tool_id: { type: :string },
          source: { type: :string, enum: %w[portal fob], description: "How the approver identified the member: fob when they tapped the member's fob; anything else is recorded as portal." } },
        required: %w[member_id tool_id]
      }
      let(:actor) { create(:member, :current, :admin) }
      let(:target) { create(:member, :current) }
      let(:tool) { create(:tool) }
      let(:checkout_details) { { member_id: target.id.to_s, tool_id: tool.id.to_s } }
      before do
        sign_in actor
        allow(REDIS).to receive(:set).and_return(true)
        allow(REDIS).to receive(:eval).and_return(1)
        allow(Service::SlackConnector).to receive(:send_slack_message)
      end
      response "200", "checkout created" do
        schema allOf: [{ "$ref" => "#/components/schemas/ToolCheckout" },
          { type: :object, properties: { unmet_prerequisites: { type: :array, items: { type: :string }, maxItems: 0 } } }]
        run_test!
      end
      response "422", "membership, tool availability, prerequisites, duplicate state or lock contention prevents creation" do
        before { tool.update!(disabled: true) }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "403", "current actor cannot approve this tool" do
        let(:actor) { create(:member, :current) }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end
end
