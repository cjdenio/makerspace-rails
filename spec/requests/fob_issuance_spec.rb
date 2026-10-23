require "rails_helper"

# Volunteers holding the (single) fob-issuer checkout may issue a member's FIRST key
# fob. Everything else about cards stays admin/board only.
RSpec.describe "Fob issuance", type: :request, requires_transactions: true do
  let(:tool) { create(:tool, name: "Fob Issuer", grants_fob_issuance: true) }
  let(:issuer) { create(:member, :current) }
  let!(:issuer_checkout) { create(:tool_checkout, member: issuer, tool: tool) }
  let(:newcomer) { create(:member, :current, status: "pending", firstname: "Nina", lastname: "Newcomer") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::AuditLogger).to receive(:attempt_slack).and_return(true)
  end

  def issue(uid: "04A1B2C3D4", member: newcomer, as: issuer)
    sign_in as
    post "/api/fob_issuance/cards", params: { member_id: member.id.to_s, uid: uid, source: "nfc" }, as: :json
  end

  describe "who may use it" do
    it "refuses a signed-out caller" do
      get "/api/fob_issuance/members", params: { search: "Ni" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an ordinary member, an admin, and a checkout on a tool that is not the fob issuer" do
      other_tool = create(:tool)
      holder = create(:member, :current)
      create(:tool_checkout, member: holder, tool: other_tool)
      [create(:member, :current), create(:member, :current, :admin), holder].each do |caller|
        sign_in caller
        get "/api/fob_issuance/members", params: { search: "Ni" }
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "refuses an issuer whose checkout was revoked or expired" do
      issuer_checkout.update_attributes!(revoked_at: Time.current)
      sign_in issuer
      get "/api/fob_issuance/members", params: { search: "Ni" }
      expect(response).to have_http_status(:forbidden)

      issuer_checkout.update_attributes!(revoked_at: nil, expires_on: Date.current - 3)
      get "/api/fob_issuance/members", params: { search: "Ni" }
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses an issuer whose own membership is expired" do
      issuer.update_attributes!(expirationTime: (Time.current - 1.day).to_i * 1000)
      sign_in issuer
      get "/api/fob_issuance/members", params: { search: "Ni" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "finding members" do
    it "lists members without a fob, matching name or email, with identity fields only" do
      newcomer
      sign_in issuer
      get "/api/fob_issuance/members", params: { search: "newcomer" }

      expect(response).to have_http_status(:ok)
      rows = JSON.parse(response.body)
      expect(rows.map { |row| row["id"] }).to eq([newcomer.id.to_s])
      expect(rows.first.keys).to include("firstname", "lastname", "email", "addressStreet", "addressPostalCode", "memberContractOnFile")
      expect(rows.first.keys).not_to include("subscriptionId", "customerId", "notes", "provisioningEmail")
    end

    it "leaves out the issuer, members who already have a fob, and revoked members" do
      carded = create(:member, :current, lastname: "Newcomer")
      create(:card, member: carded)
      revoked = create(:member, :current, lastname: "Newcomer", status: "revoked")
      issuer.update_attributes!(lastname: "Newcomer")
      newcomer
      sign_in issuer
      get "/api/fob_issuance/members", params: { search: "Newcomer" }

      expect(JSON.parse(response.body).map { |row| row["id"] }).to eq([newcomer.id.to_s])
      expect(JSON.parse(response.body).map { |row| row["id"] }).not_to include(carded.id.to_s, revoked.id.to_s, issuer.id.to_s)
    end

    it "treats a member whose only card is lost as still waiting for a first fob" do
      lost_card = create(:card, member: newcomer)
      lost_card.set(validity: "lost")
      sign_in issuer
      get "/api/fob_issuance/members/#{newcomer.id}"
      expect(response).to have_http_status(:ok)
    end

    it "returns nothing for a very short search" do
      sign_in issuer
      get "/api/fob_issuance/members", params: { search: "N" }
      expect(JSON.parse(response.body)).to eq([])
    end

    it "does not show the profile of a member who already has a fob" do
      carded = create(:member, :current)
      create(:card, member: carded)
      sign_in issuer
      get "/api/fob_issuance/members/#{carded.id}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "issuing a first fob" do
    it "registers the fob, activates a pending member, and sends the Slack messages" do
      expect(Service::SlackConnector).to receive(:enque_message).with(/Nina Newcomer.*issued a key fob/, anything, anything)

      issue

      expect(response).to have_http_status(:ok)
      card = Card.find_by(uid: "04A1B2C3D4")
      expect(card.member_id).to eq(newcomer.id)
      expect(newcomer.reload.status).to eq("activeMember")
    end

    it "direct messages the member when their Slack account is linked" do
      SlackUser.create!(member_id: newcomer.id, slack_id: "U123NINA", name: "nina")
      expect(Service::SlackConnector).to receive(:enque_message).with(/Your key fob has been issued/, "U123NINA", anything)
      expect(Service::SlackConnector).to receive(:enque_message).with(/was issued a key fob/, anything, anything)

      issue

      expect(response).to have_http_status(:ok)
    end

    it "records the issuer in the card audit" do
      issue
      log = AuditLog.where(event_type: "card_assigned").last
      expect(log.actor_id.to_s).to eq(issuer.id.to_s)
    end

    it "will not issue to oneself" do
      issue(member: issuer)
      expect(response).to have_http_status(:not_found)
      expect(Card.where(member_id: issuer.id).count).to eq(0)
    end

    it "will not replace an existing fob" do
      existing = create(:card, member: newcomer)
      issue
      expect(response).to have_http_status(:not_found)
      expect(existing.reload.validity).not_to eq("lost")
      expect(Card.where(uid: "04A1B2C3D4").count).to eq(0)
    end

    it "refuses the assignment inside the transaction if a card appeared after the search" do
      # The search said eligible; a card is registered before the assignment commits.
      allow_any_instance_of(FobIssuanceController).to receive(:eligible_members).and_return(Member.where(id: newcomer.id))
      create(:card, member: newcomer)
      issue
      expect(response).to have_http_status(:conflict)
    end

    it "will not issue to a revoked member" do
      revoked = create(:member, :current, status: "revoked")
      issue(member: revoked)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a malformed UID" do
      issue(uid: "not-a-uid")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects a UID that is already registered" do
      create(:card, uid: "04A1B2C3D4", member: create(:member, :current))
      issue
      expect(response).to have_http_status(:conflict)
    end

    it "offers the most recent unclaimed reader rejection as the candidate UID" do
      RejectionCard.create!(uid: "04FF00FF", timeOf: Time.current)
      sign_in issuer
      get "/api/fob_issuance/cards/new"
      expect(JSON.parse(response.body)["uid"]).to eq("04FF00FF")
    end
  end

  describe "the isFobIssuer profile flag" do
    it "is true on a fob issuer's profile and false for everyone else" do
      sign_in issuer
      get "/api/members/#{issuer.id}"
      expect(JSON.parse(response.body)["isFobIssuer"]).to be(true)

      sign_in newcomer
      get "/api/members/#{newcomer.id}"
      expect(JSON.parse(response.body)["isFobIssuer"]).to be(false)
    end

    it "is in the sign-in response, which the portal reads for the signed-in member" do
      post "/api/members/sign_in", params: { member: { email: issuer.email, password: "password" } }, as: :json
      expect(JSON.parse(response.body)["isFobIssuer"]).to be(true)
    end
  end

  describe "the fob issuer tool flag" do
    it "allows only one tool to carry it" do
      tool
      second = build(:tool, grants_fob_issuance: true)
      expect(second).not_to be_valid
      expect(second.errors[:grants_fob_issuance].join).to include("Fob Issuer")
    end

    it "can be set by a board member but not by a resource manager" do
      tool.set(grants_fob_issuance: false)
      plain = create(:tool)
      sign_in create(:member, :current, :resource_manager, resource_manager_shop_ids: [plain.shop_id.to_s])
      put "/api/admin/tools/#{plain.id}", params: { grants_fob_issuance: true }, as: :json
      expect(plain.reload.grants_fob_issuance).to be(false)

      sign_in create(:member, :current, role: "board_member")
      put "/api/admin/tools/#{plain.id}", params: { grants_fob_issuance: true }, as: :json
      expect(plain.reload.grants_fob_issuance).to be(true)
    end
  end
end
