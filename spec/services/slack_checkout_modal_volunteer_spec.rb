require "rails_helper"

RSpec.describe SlackCheckoutModal do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool, shop: shop) }
  let!(:checkout) { create(:tool_checkout, member: member, tool: tool, checked_out_at: Time.zone.local(2026, 4, 5)) }
  let(:request) { CheckoutApproverRequest.create!(member: member, tool: tool, note: "I teach this tool") }

  def view(step, volunteer_request: nil)
    described_class.new(member: member, shop: shop, tool: tool, volunteer_request: volunteer_request,
      metadata: { "member_id" => member.id.to_s, "shop_id" => shop.id.to_s,
        "slack_user_id" => "U1", "step" => step, "record_id" => volunteer_request&.id&.to_s }).build
  end

  it "accepts an optional note when volunteering" do
    note = view("volunteer_confirm").fetch(:blocks).find { |block| block[:block_id] == described_class::NOTE }
    expect(note).to include(type: "input", optional: true)
  end

  it "shows request context and both RM decisions" do
    rendered = view("volunteer_detail", volunteer_request: request)
    text = rendered.to_json
    expect(text).to include("I teach this tool", "2026-04-05", "Approve volunteer", "Decline volunteer")
  end

  %w[volunteer_approve volunteer_decline].each do |step|
    it "accepts an optional RM note for #{step.delete_prefix('volunteer_')}" do
      note = view(step, volunteer_request: request).fetch(:blocks).find { |block| block[:block_id] == described_class::NOTE }
      expect(note).to include(type: "input", optional: true)
    end
  end
end
