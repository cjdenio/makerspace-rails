require "rails_helper"

RSpec.describe CheckoutInteractionQuery do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  subject(:query) { described_class.new(member: member, shop: shop) }

  it "sorts enabled shops and requestable tools case insensitively" do
    Shop.delete_all
    z = create(:shop, name: "Zebra")
    a = create(:shop, name: "alpha")
    create(:shop, name: "Disabled", disabled: true)
    expect(described_class.new(member: member).enabled_shops.map(&:id)).to eq([a.id, z.id])
    zebra = create(:tool, shop: shop, name: "Zebra")
    alpha = create(:tool, shop: shop, name: "alpha")
    create(:tool, shop: shop, disabled: true)
    create(:tool, shop: shop, open: true)
    create(:tool)
    expect(query.requestable_tools.map(&:id)).to eq([alpha.id, zebra.id])
  end

  it "bulk loads eligibility, including cross-shop prerequisites and revoked target records" do
    prerequisite = create(:tool)
    create(:tool_checkout, member: member, tool: prerequisite)
    eligible = create(:tool, shop: shop, prerequisite_ids: [prerequisite.id.to_s])
    revoked = create(:tool, shop: shop)
    create(:tool_checkout, member: member, tool: revoked, revoked_at: Time.current)
    requested = create(:tool, shop: shop)
    ToolCheckoutRequest.create!(member: member, tool: requested)
    expect(ToolCheckout).to receive(:where).once.and_call_original
    expect(ToolCheckoutRequest).to receive(:where).once.and_call_original
    expect(query.requestable_tools.map(&:id)).to eq([eligible.id])
  end

  it "returns only this member's active checkouts in the selected shop" do
    tool = create(:tool, shop: shop)
    checkout = create(:tool_checkout, member: member, tool: tool)
    create(:tool_checkout, member: member, tool: create(:tool))
    create(:tool_checkout, member: member, tool: create(:tool, shop: shop), revoked_at: Time.current)
    expect(query.active_checkouts.to_a).to eq([checkout])
  end

  it "filters ineligible members even for administrators and restricts pending requests by tool" do
    member.update!(role: "admin")
    tool = create(:tool, shop: shop)
    pending_tool = create(:tool, shop: shop, allow_pending: true)
    active = create(:member, :current)
    pending = create(:member, :current, status: "pending")
    visible = [ToolCheckoutRequest.create!(member: active, tool: tool),
               ToolCheckoutRequest.create!(member: pending, tool: pending_tool)]
    ToolCheckoutRequest.create!(member: pending, tool: tool)
    %w[revoked suspended inactive nonMember].each do |status|
      ToolCheckoutRequest.create!(member: create(:member, :current, status: status), tool: tool)
    end
    ToolCheckoutRequest.create!(member: create(:member, :expired), tool: tool)
    expect(query.open_requests(for_approval: true).map(&:id)).to eq(visible.map(&:id))
  end

  it "limits approval queues to assigned tools and personal lists to the acting member" do
    tool = create(:tool, shop: shop)
    other = create(:tool, shop: shop)
    own = ToolCheckoutRequest.create!(member: member, tool: other)
    assigned = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
    create(:checkout_approver, member: member, shop_ids: [], tool_ids: [tool.id.to_s])
    expect(query.open_requests.map(&:id)).to eq([own.id])
    expect(query.open_requests(for_approval: true).map(&:id)).to eq([assigned.id])
  end

  it "preserves manager access to disabled tools but denies ordinary approvers that access" do
    member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
    disabled = create(:tool, shop: shop, disabled: true)
    row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: disabled)
    expect(query.open_requests(for_approval: true).map(&:id)).to eq([row.id])
    member.update!(role: "member", resource_manager_shop_ids: [])
    create(:checkout_approver, member: member, shop_ids: [shop.id.to_s])
    expect(query.open_requests(for_approval: true)).to be_empty
  end

  it "orders equal request dates by id in Mongo" do
    tool = create(:tool, shop: shop)
    date = Time.current
    rows = 2.times.map { ToolCheckoutRequest.create!(member: member, tool: tool, request_date: date) }
    expect(query.open_requests.options[:sort]).to eq("request_date" => 1, "_id" => 1)
    expect(query.open_requests.map(&:id)).to eq(rows.map(&:id).sort)
  end

  it "orders active checkout options in Mongo and bulk-loads the same tool content for text and modal" do
    z = create(:tool, shop: shop, name: "Zebra")
    a = create(:tool, shop: shop, name: "alpha")
    create(:tool_checkout, member: member, tool: z)
    create(:tool_checkout, member: member, tool: a)
    rows = query.listed_active_checkouts
    expect(rows.map { |row| row.tool.name }).to eq(%w[alpha Zebra])
    expect(CheckoutDisplay.text(rows)).to include(*rows.flat_map { |row| CheckoutDisplay.details(row).map { |line| CheckoutDisplay.escape(line) } })
  end

  it "unions own and assigned open requests without leaking other shops or ineligible requesters" do
    assigned = create(:tool, shop: shop)
    outside = create(:tool)
    create(:checkout_approver, member: member, tool_ids: [assigned.id.to_s, outside.id.to_s], shop_ids: [])
    own = ToolCheckoutRequest.create!(member: member, tool: create(:tool, shop: shop))
    approved = ToolCheckoutRequest.create!(member: create(:member, :current), tool: assigned)
    ToolCheckoutRequest.create!(member: create(:member, :current), tool: outside)
    ToolCheckoutRequest.create!(member: create(:member, :expired), tool: assigned)
    expect(query.visible_open_requests.map(&:id)).to eq([own.id, approved.id])
  end

  it "shows volunteer requests to tagged admin and board shop contacts" do
    tool = create(:tool, shop: shop)
    volunteer = create(:member, :current)
    create(:tool_checkout, member: volunteer, tool: tool)
    request = CheckoutApproverRequest.create!(member: volunteer, tool: tool)

    %w[admin board_member].each do |role|
      member.update!(role: role, resource_manager_shop_ids: [shop.id.to_s])
      expect(query.visible_volunteer_requests.map(&:id)).to eq([request.id])
    end
  end

end
