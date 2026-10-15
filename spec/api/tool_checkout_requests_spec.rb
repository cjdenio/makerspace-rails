require "swagger_helper"

describe "Tool checkout requests API", type: :request do
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  path "/tool_checkout_requests" do
    get "Lists the member's eligible open checkout requests" do
      parameter name: :include_groups, in: :query, required: false, schema: { type: :boolean }, description: 'Opt in to group targets; default remains tool-only.'
      tags "ToolCheckoutRequests"
      description "Returns open requests for enabled tools belonging to the signed-in member. Excludes inactive, expired, revoked and suspended members; pending members require a tool allowing pending members. Defaults to request_date then id ascending. requestorAnnotation is the current tool annotation, falling back to its shop, or null. Group targets use the group shop annotation."
      produces "application/json"
      response "200", "eligible open requests" do
        let(:member) { create(:member, :current) }
        let(:tool) { create(:tool) }
        let!(:visible_request) { ToolCheckoutRequest.create!(member: member, tool: tool) }
        before do
          ToolCheckoutRequest.create!(member: create(:member, :current, status: "suspended"), tool: tool)
          sign_in member
        end
        schema type: :array, items: { type: :object, properties: { requestorAnnotation: { type: :string, nullable: true } } }
        run_test! do |response|
          expect(JSON.parse(response.body).map { |row| row.fetch("id") }).to eq([visible_request.id.to_s])
        end
      end
    end

    post "Requests a safety checkout" do
      tags "ToolCheckoutRequests"
      operationId "createToolCheckoutRequest"
      description "Creation is serialized under the shared per-member/tool lock (groups acquire the catalog and constituent-tool locks), with membership, availability, prerequisites, checkout records and open requests rechecked immediately before insertion. Lock contention returns 422. Successful submission sends a Slack DM to the linked requestor including the tool annotation, or the shop annotation when the tool has none."
      consumes "application/json"
      produces "application/json"
      parameter name: :request_details, in: :body, schema: {
        type: :object,
        properties: {
          tool_id: { type: :string },
          tool_group_id: { type: :string },
          note: { type: :string }
        },
        oneOf: [{ required: ['tool_id'] }, { required: ['tool_group_id'] }]
      }

      response "200", "checkout request created" do
        let(:member) { create(:member, :current) }
        let(:tool) { create(:tool) }
        let(:request_details) { { tool_id: tool.id.to_s, note: "Please train me" } }
        before do
          sign_in member
          allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
        end

        schema type: :object,
          properties: {
            id: { type: :string },
            memberId: { type: :string },
            memberName: { type: :string },
            memberEmail: { type: :string },
            memberStatus: { type: :string },
            toolId: { type: :string, nullable: true },
            toolGroupId: { type: :string, nullable: true },
            targetType: { type: :string, enum: %w[tool group] },
            targetName: { type: :string },
            groupRevision: { type: :integer, nullable: true },
            includedToolIds: { type: :array, items: { type: :string } },
            toolName: { type: :string },
            shopId: { type: :string },
            shopName: { type: :string },
            note: { type: :string, nullable: true },
            requestorAnnotation: { type: :string, nullable: true },
            requestDate: { type: :string, format: "date-time" },
            status: { type: :string },
            messageId: { type: :string, nullable: true },
            checkedOutId: { type: :string, nullable: true },
            memberSlackUrl: { type: :string, nullable: true }
          },
          required: %w[
            id memberId memberName memberEmail memberStatus toolId toolName
            toolGroupId targetType targetName groupRevision includedToolIds
            shopId shopName note requestDate status messageId checkedOutId memberSlackUrl
          ],
          oneOf: [
            { properties: { targetType: { enum: ['tool'] }, toolId: { type: :string }, toolGroupId: { type: :string, nullable: true, enum: [nil] } } },
            { properties: { targetType: { enum: ['group'] }, toolId: { type: :string, nullable: true, enum: [nil] }, toolGroupId: { type: :string }, groupRevision: { type: :integer } } }
          ]
        context 'individual tool target' do
          run_test!
        end
        context 'group target' do
          let(:group) { ToolGroup.create!(shop: tool.shop, name: 'Safety kit', included_tool_ids: [tool.id.to_s], requestable: true) }
          let(:request_details) { { tool_group_id: group.id.to_s, note: 'Please train me' } }
          run_test! do |response|
            expect(JSON.parse(response.body)).to include('toolId' => nil, 'toolGroupId' => group.id.to_s,
              'targetType' => 'group', 'targetName' => group.name, 'groupRevision' => group.revision,
              'includedToolIds' => [tool.id.to_s])
          end
        end
      end

      response "422", "tool is not eligible, prerequisites are unmet, or a record/request exists" do
        schema "$ref" => "#/components/schemas/error"

        context "with an unmet prerequisite" do
          let(:member) { create(:member, :current) }
          let(:prerequisite) { create(:tool) }
          let(:tool) { create(:tool, shop: prerequisite.shop, prerequisite_ids: [prerequisite.id.to_s]) }
          let(:request_details) { { tool_id: tool.id.to_s } }
          before { sign_in member }

          run_test!
        end

        context "with a revoked checkout for the requested tool" do
          let(:member) { create(:member, :current) }
          let(:tool) { create(:tool) }
          let(:request_details) { { tool_id: tool.id.to_s } }
          before do
            create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)
            sign_in member
          end

          run_test!
        end
      end

      response "403", "membership is not eligible to request a checkout" do
        let(:member) { create(:member, :inactive) }
        let(:tool) { create(:tool, open: false) }
        let(:request_details) { { tool_id: tool.id.to_s } }
        before { sign_in member }

        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end
end


describe "Checkout approval queue API", type: :request do
  path "/admin/tool_checkout_requests/{id}/decline" do
    parameter name: :id, in: :path, type: :string

    post "Declines an open checkout request" do
      tags "ToolCheckoutRequests"
      operationId "declineToolCheckoutRequest"
      description "Admin or board member, the shop's resource manager, or an approver assigned to the tool, its shop or the group may decline an open request. A reason of at most 255 characters is required and is sent to the requester by Slack DM. The decision runs under the same locks as approval and cancellation, so only one can apply. A declined request is no longer open, so the member may request again. Returns 422 for a missing or overlong reason or a request that is no longer open, and 403 for a caller who may not approve it."
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, required: ["reason"], properties: { reason: { type: :string, maxLength: 255 } } }

      let(:shop) { create(:shop) }
      let(:tool) { create(:tool, shop: shop) }
      let(:requester) { create(:member, :current) }
      let!(:checkout_request) { ToolCheckoutRequest.create!(member: requester, tool: tool) }
      let(:id) { checkout_request.id.to_s }
      let(:body) { { reason: "Needs the safety class first" } }

      response "200", "declined request" do
        let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
        before { sign_in manager }
        schema "$ref" => "#/components/schemas/ToolCheckoutRequest"
        run_test! do |response|
          json = JSON.parse(response.body)
          expect(json).to include("status" => "declined", "decisionReason" => "Needs the safety class first",
                                  "decidedByName" => manager.fullname)
          expect(checkout_request.reload).to be_declined
        end
      end

      response "422", "reason missing" do
        let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
        let(:body) { { reason: " " } }
        before { sign_in manager }
        run_test! { expect(checkout_request.reload).to be_open }
      end

      response "403", "caller cannot approve this request" do
        let(:outsider) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s]) }
        before { sign_in outsider }
        run_test! { expect(checkout_request.reload).to be_open }
      end
    end
  end

  path "/admin/tool_checkout_requests" do
    get "Lists authorized eligible open checkout requests" do
      parameter name: :include_groups, in: :query, required: false, schema: { type: :boolean }, description: 'Include group requests for which the viewer has group approval authority.'
      tags "ToolCheckoutRequests"
      description "Admins and board members see all tool scopes; resource managers see managed shops; valid checkout approvers see assigned enabled tools and shops. All scopes exclude inactive, expired, revoked and suspended requesters. Pending requesters require a tool allowing pending members. Defaults to request_date then id ascending."
      produces "application/json"
      response "200", "authorized open requests" do
        let(:member) { create(:member, :current, role: "admin") }
        let(:tool) { create(:tool) }
        let!(:visible_request) { ToolCheckoutRequest.create!(member: member, tool: tool) }
        before do
          ToolCheckoutRequest.create!(member: create(:member, :current, status: "suspended"), tool: tool)
          sign_in member
        end
        schema type: :array, items: { type: :object }
        run_test! do |response|
          expect(JSON.parse(response.body).map { |row| row.fetch("id") }).to eq([visible_request.id.to_s])
        end
      end
    end
  end
end


describe "Checkout request mutations API", type: :request do
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }
  let(:row) { ToolCheckoutRequest.create!(member: member, tool: tool) }
  let(:id) { row.id.to_s }
  before do
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:remove_announcement)
  end
  path "/tool_checkout_requests/{id}" do
    parameter name: :id, in: :path, type: :string
    put "Edits an owned open request note" do
      tags "ToolCheckoutRequests"
      description "Owner and open status are rechecked inside the same locks used by approval and cancellation: catalog and constituent-tool locks for groups, member/tool lock for tools. Tool and shop must still be available."
      consumes "application/json"
      produces "application/json"
      parameter name: :details, in: :body, schema: { type: :object, properties: { note: { type: :string, maxLength: 128 } } }
      let(:details) { { note: "Updated note" } }
      response "200", "note updated" do
        schema type: :object
        context 'individual tool target' do
          run_test! { expect(row.reload.note).to eq("Updated note") }
        end
        context 'group target' do
          let(:group) { ToolGroup.create!(shop: tool.shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
          let(:row) { ToolCheckoutRequest.create!(member: member, tool_group: group) }
          run_test! { expect(row.reload.note).to eq('Updated note') }
        end
      end
      response "403", "request is no longer open or not owned by the caller" do
        before { row.update!(status: "closed") }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "422", "note validation or checkout lock contention" do
        let(:details) { { note: "x" * 129 } }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
    delete "Cancels an owned open request" do
      tags "ToolCheckoutRequests"
      description "Cancellation and approval serialize under the same locks, including the catalog and constituent-tool locks for groups. A successful cancellation retains the existing announcement-removal behavior."
      produces "application/json"
      response "204", "request cancelled" do
        context 'individual tool target' do
          run_test! { expect(row.reload.status).to eq("deleted") }
        end
        context 'group target' do
          let(:group) { ToolGroup.create!(shop: tool.shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
          let(:row) { ToolCheckoutRequest.create!(member: member, tool_group: group) }
          run_test! { expect(row.reload.status).to eq('deleted') }
        end
      end
      response "403", "request is no longer open or not owned by the caller" do
        before { row.update!(status: "closed") }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "422", "another checkout mutation holds the lock" do
        before { allow(REDIS).to receive(:set).and_return(false) }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end
end
