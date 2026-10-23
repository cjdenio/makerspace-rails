require "rails_helper"

RSpec.describe "Fob lookup for a tool checkout", type: :request do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, name: "Laguna Bandsaw") }
  let(:member) { create(:member, :current, firstname: "Pat", lastname: "Member") }
  let(:uid) { "04A1B2C3" }
  let!(:card) { create(:card, member: member, uid: uid) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def lookup(as:, uid: self.uid, tool_id: tool.id.to_s)
    sign_in as if as
    post "/api/admin/tool_checkouts/lookup_card", params: { tool_id: tool_id, uid: uid }, as: :json
  end

  def approver_for(**assignment)
    approver = create(:member, :current, member_contract_signed_date: Date.current)
    CheckoutApprover.create!({ member: approver }.merge(assignment))
    approver
  end

  describe "who may look up a fob" do
    it "refuses a signed-out caller" do
      lookup(as: nil)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an ordinary member, a resource manager of another shop, and an approver of another tool" do
      outsiders = [
        create(:member, :current),
        create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s]),
        approver_for(tool_ids: [create(:tool).id.to_s]),
        approver_for(shop_ids: [create(:shop).id.to_s])
      ]
      outsiders.each do |outsider|
        lookup(as: outsider)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include("Pat Member")
      end
    end

    it "allows admin, board, the shop's resource manager, and approvers assigned to the tool or its shop" do
      allowed = [
        create(:member, :admin, :current),
        create(:member, :board_member, :current),
        create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]),
        approver_for(tool_ids: [tool.id.to_s]),
        approver_for(shop_ids: [shop.id.to_s])
      ]
      allowed.each do |actor|
        lookup(as: actor)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to include("memberId" => member.id.to_s, "name" => member.fullname)
      end
    end
  end

  describe "what comes back" do
    let(:admin) { create(:member, :admin, :current) }

    it "returns only what is needed to confirm the person, and is not cached" do
      lookup(as: admin)

      body = JSON.parse(response.body)
      expect(body.keys).to contain_exactly("memberId", "name", "status", "expirationTime", "eligible", "error",
                                           "unmetPrerequisites")
      expect(body).to include("eligible" => true, "error" => nil, "unmetPrerequisites" => [], "status" => "activeMember")
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "marks a member who cannot be checked out and says why" do
      member.update!(expirationTime: 1.day.ago.to_i * 1000)

      lookup(as: admin)

      expect(JSON.parse(response.body)).to include("eligible" => false)
      expect(JSON.parse(response.body)["error"]).to be_present
    end

    it "lists unmet prerequisites by name" do
      prerequisite = create(:tool, shop: shop, name: "Safety Orientation")
      tool.update!(prerequisite_ids: [prerequisite.id.to_s])

      lookup(as: admin)

      body = JSON.parse(response.body)
      expect(body).to include("eligible" => false, "unmetPrerequisites" => ["Safety Orientation"])
    end

    it "marks a member who already holds the tool as not eligible" do
      ToolCheckout.create!(member: member, tool: tool, approved_by: admin)

      lookup(as: admin)

      expect(JSON.parse(response.body)).to include("eligible" => false)
    end

    it "refuses a fob reported lost or stolen without naming the member" do
      %w[lost stolen].each do |validity|
        card.set(validity: validity)

        lookup(as: admin)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to include("Pat Member")
      end
    end

    it "does not treat an open request as a reason to refuse" do
      ToolCheckoutRequest.create!(member: member, tool: tool)

      lookup(as: admin)

      expect(JSON.parse(response.body)).to include("eligible" => true)
    end
  end

  describe "bad input" do
    let(:admin) { create(:member, :admin, :current) }

    it "rejects a malformed UID without looking anything up" do
      ["04a1b2c3", "XYZ", "04A1B2C", ""].each do |bad|
        lookup(as: admin, uid: bad)

        expect(response).to have_http_status(:unprocessable_content).or have_http_status(:bad_request)
      end
    end

    it "returns not found for an unknown fob, an unknown tool, and a card with no member" do
      lookup(as: admin, uid: "AABBCCDD")
      expect(response).to have_http_status(:not_found)

      lookup(as: admin, tool_id: BSON::ObjectId.new.to_s)
      expect(response).to have_http_status(:not_found)

      Card.collection.update_one({ _id: card.id }, { "$set" => { member_id: nil } })
      lookup(as: admin)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "recording the checkout" do
    let(:admin) { create(:member, :admin, :current) }

    def checkout(source: nil)
      sign_in admin
      post "/api/admin/tool_checkouts", params: { member_id: member.id.to_s, tool_id: tool.id.to_s, source: source }.compact,
                                         as: :json
    end

    it "records a fob sign-off as fob" do
      checkout(source: "fob")

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.last.signed_off_via).to eq("fob")
    end

    it "closes the member's open request when the fob checkout is recorded" do
      request = ToolCheckoutRequest.create!(member: member, tool: tool)

      checkout(source: "fob")

      expect(request.reload).to have_attributes(status: "closed", checked_out_id: ToolCheckout.last.id)
    end

    it "records anything else, or nothing, as portal" do
      checkout
      expect(ToolCheckout.last.signed_off_via).to eq("portal")
      ToolCheckout.delete_all

      checkout(source: "anything")
      expect(ToolCheckout.last.signed_off_via).to eq("portal")
    end
  end
  describe "checking out on a tool group" do
    let(:admin) { create(:member, :admin, :current) }
    let(:other_tool) { create(:tool, shop: shop, name: "Drill Press") }
    let(:group) { ToolGroup.create!(shop: shop, name: "Wood kit", included_tool_ids: [tool.id.to_s, other_tool.id.to_s]) }

    def lookup_group(as:, group_id: group.id.to_s, uid: self.uid)
      sign_in as
      post "/api/admin/tool_checkouts/lookup_card", params: { tool_group_id: group_id, uid: uid }, as: :json
    end

    it "returns the member and eligibility for a group" do
      lookup_group(as: admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("memberId" => member.id.to_s, "eligible" => true)
    end

    it "marks the member not eligible when every tool in the group is already held" do
      [tool, other_tool].each { |held| ToolCheckout.create!(member: member, tool: held, approved_by: admin) }

      lookup_group(as: admin)

      expect(JSON.parse(response.body)).to include("eligible" => false)
      expect(JSON.parse(response.body)["error"]).to be_present
    end

    it "uses the same authority rule as approving the group" do
      outsider = create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s])
      lookup_group(as: outsider)
      expect(response).to have_http_status(:forbidden)

      manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      lookup_group(as: manager)
      expect(response).to have_http_status(:ok)
    end

    it "needs exactly one of a tool or a group, and returns not found for an unknown group" do
      sign_in admin
      post "/api/admin/tool_checkouts/lookup_card", params: { uid: uid }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/admin/tool_checkouts/lookup_card",
           params: { uid: uid, tool_id: tool.id.to_s, tool_group_id: group.id.to_s }, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      lookup_group(as: admin, group_id: BSON::ObjectId.new.to_s)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the audit trail" do
    let(:admin) { create(:member, :admin, :current) }

    def lookups
      AuditLog.where(event_type: "fob_checkout_lookup")
    end

    it "records every lookup whatever its outcome, with the target and the end of the UID, and no Slack post" do
      lookup(as: admin)
      lookup(as: admin, uid: "AABBCCDD")
      lookup(as: admin, uid: "nope")
      card.set(validity: "lost")
      lookup(as: admin)
      lookup(as: create(:member, :current))

      results = lookups.map { |entry| entry.after_snapshot["result"] }
      expect(results).to contain_exactly("found", "not_found", "invalid_uid", "lost_or_stolen", "forbidden")
      found = lookups.detect { |entry| entry.after_snapshot["result"] == "found" }
      expect(found).to have_attributes(actor_id: admin.id, subject_id: member.id, resource_id: tool.id)
      expect(found.after_snapshot).to include("uid_tail" => "B2C3", "target_name" => "Laguna Bandsaw", "eligible" => true)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it "does not throttle repeated lookups" do
      30.times { lookup(as: admin) }

      expect(response).to have_http_status(:ok)
      expect(lookups.count).to eq(30)
    end
  end
end
