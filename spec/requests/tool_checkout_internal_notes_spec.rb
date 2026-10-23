require "rails_helper"

# Revocation/reinstatement reasons, the request note and who revoked/reinstated
# are internal: only approvers of the tool, RMs of its shop, board and admins.
RSpec.describe "Tool checkout internal notes", type: :request do
  NOTE_KEYS = %w[revocationReason requestNote revokedById revokedByName reinstatementReason
                 reinstatedById reinstatedByName reinstatedAt].freeze

  let(:shop) { create(:shop) }
  let(:other_shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:admin) { create(:member, :current, :admin) }
  let(:board) { create(:member, :current, role: "board_member") }
  let(:resource_manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
  let(:other_rm) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [other_shop.id.to_s]) }
  let(:approver) { create(:member, :current) }
  let(:other_approver) { create(:member, :current) }
  let(:owner) { create(:member, :current) }
  let(:stranger) { create(:member, :current) }

  let!(:revoked) do
    create(:tool_checkout, member: owner, tool: tool, approved_by: admin, request_note: "Wants to build a table").tap do |row|
      row.update!(revoked_at: 2.days.ago, revocation_reason: "Safety retraining", revoked_by_id: admin.id)
    end
  end
  let!(:replacement) do
    create(:tool_checkout, member: owner, tool: tool, approved_by: admin, reinstated_from_id: revoked.id,
      reinstatement_reason: "Retrained", reinstated_by_id: board.id, reinstated_at: 1.day.ago)
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    CheckoutApprover.create!(member: other_approver, shop_ids: [other_shop.id.to_s])
  end

  def admin_rows
    get "/api/admin/tool_checkouts"
    JSON.parse(response.body).index_by { |row| row["id"] }
  end

  [:admin, :board, :resource_manager, :approver].each do |role|
    it "includes the notes for #{role}" do
      sign_in public_send(role)
      rows = admin_rows
      expect(rows[revoked.id.to_s]).to include("revocationReason" => "Safety retraining",
        "requestNote" => "Wants to build a table", "revokedById" => admin.id.to_s,
        "revokedByName" => admin.fullname)
      expect(rows[replacement.id.to_s]).to include("reinstatementReason" => "Retrained",
        "reinstatedById" => board.id.to_s, "reinstatedByName" => board.fullname)
      expect(rows[replacement.id.to_s]["reinstatedAt"]).to be_present
    end
  end

  it "omits the notes from the member's own checkouts" do
    sign_in owner
    get "/api/tool_checkouts"
    rows = JSON.parse(response.body)
    expect(rows.size).to eq(2)
    rows.each { |row| expect(row.keys & NOTE_KEYS).to be_empty }
    expect(response.body).not_to include("Safety retraining", "Retrained", "Wants to build a table")
  end

  it "omits the notes from the member's own checkouts even when they are an approver for the tool" do
    CheckoutApprover.create!(member: owner, tool_ids: [tool.id.to_s])
    sign_in owner
    get "/api/tool_checkouts"
    JSON.parse(response.body).each { |row| expect(row.keys & NOTE_KEYS).to be_empty }
  end

  it "does not let an ordinary member read another member's checkouts" do
    sign_in stranger
    get "/api/admin/tool_checkouts"
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("Safety retraining")
  end

  [:other_approver, :other_rm].each do |viewer|
    it "does not show notes to #{viewer}, who cannot approve this tool" do
      sign_in public_send(viewer)
      rows = admin_rows
      expect(rows).not_to have_key(revoked.id.to_s)
      expect(response.body).not_to include("Safety retraining", "Retrained", "Wants to build a table")
    end
  end

  it "never serializes the notes for a viewer without privilege over the tool" do
    [stranger, other_approver, other_rm, owner].each do |viewer|
      json = ActiveModelSerializers::SerializableResource.new([revoked, replacement],
        each_serializer: ToolCheckoutSerializer, adapter: :attributes, scope: viewer).as_json
      json.each { |row| expect(row.keys.map(&:to_s) & NOTE_KEYS.map { |k| k.underscore }).to be_empty }
    end
  end

  it "requires authentication" do
    get "/api/admin/tool_checkouts"
    expect(response).to have_http_status(:unauthorized)
    get "/api/tool_checkouts"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "reinstated status" do
    it "marks the revoked row as superseded and points at the active checkout, for everyone who sees it" do
      sign_in owner
      get "/api/tool_checkouts"
      rows = JSON.parse(response.body).index_by { |row| row["id"] }
      expect(rows[revoked.id.to_s]).to include("reinstated" => true, "reinstatedByCheckoutId" => replacement.id.to_s)
      expect(rows[replacement.id.to_s]).to include("reinstated" => false, "reinstatedByCheckoutId" => nil)
    end

    it "does not mark a revoked row as reinstated when the replacement is itself revoked" do
      replacement.update!(revoked_at: Time.current, revocation_reason: "Again", revoked_by_id: admin.id)
      sign_in admin
      expect(admin_rows[revoked.id.to_s]).to include("reinstated" => false)
    end

    it "filters reinstated pairs and excludes superseded rows from revoked-only" do
      plain = create(:tool_checkout, member: stranger, tool: tool, approved_by: admin)
      plain_revoked = create(:tool_checkout, member: approver, tool: tool, approved_by: admin).tap do |row|
        row.update!(revoked_at: Time.current, revocation_reason: "x", revoked_by_id: admin.id)
      end
      sign_in admin

      get "/api/admin/tool_checkouts", params: { reinstated: "true" }
      expect(JSON.parse(response.body).map { |r| r["id"] }).to contain_exactly(revoked.id.to_s, replacement.id.to_s)

      get "/api/admin/tool_checkouts", params: { active: "false", reinstated: "false" }
      expect(JSON.parse(response.body).map { |r| r["id"] }).to eq([plain_revoked.id.to_s])

      get "/api/admin/tool_checkouts", params: { reinstated: "false" }
      expect(JSON.parse(response.body).map { |r| r["id"] }).to contain_exactly(replacement.id.to_s, plain.id.to_s, plain_revoked.id.to_s)
    end
  end
end
