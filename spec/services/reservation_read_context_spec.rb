require "rails_helper"

RSpec.describe ReservationReadContext do
  include ReservationReadMeasurement

  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }

  def insert_tools(count, **attributes)
    rows = Array.new(count) { |index| Tool.new(shop: shop, name: "Tool #{index}", reservable: true, **attributes) }
    Tool.collection.insert_many(rows.map(&:attributes))
    rows
  end

  [1, 25, 100].each do |count|
    it "batches eligibility and missing prerequisite names for #{count} tools" do
      prerequisite = create(:tool, shop: shop, reservable: false)
      rows = insert_tools(count, reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
      ToolCheckout.collection.insert_many(([prerequisite] + rows).map do |tool|
        ToolCheckout.new(member: member, tool: tool).attributes
      end)
      context = described_class.new(shop: shop, member: member)
      measurement = measure_reservation_reads do
        expect(context.eligible_tools.map(&:id)).to match_array(rows.map(&:id))
        ids = rows.map(&:id) + [prerequisite.id, BSON::ObjectId.new]
        names = context.tool_names(ids)
        expect(names[prerequisite.id.to_s]).to eq(prerequisite.name)
        expect(names[ids.last.to_s]).to be_nil
        context.eligible_tools
        context.tool_names(ids)
      end
      expect(measurement[:commands].reject { |command, _| command == "getMore" }.tally).to eq(
        ["find", "tools"] => 2, ["find", "tool_checkouts"] => 1
      )
    end
  end

  it "skips empty supplemental name and fee lookups" do
    context = described_class.new
    expect(measure_reservation_reads do
      expect(context.tool_names([])).to eq({})
      expect(context.invoice_options([])).to eq({})
    end[:commands]).to be_empty
  end

  it "does not retain a revoked checkout across contexts" do
    tool = insert_tools(1).first
    checkout = ToolCheckout.new(member: member, tool: tool)
    ToolCheckout.collection.insert_one(checkout.attributes)
    expect(described_class.new(shop: shop, member: member).eligible_tools.map(&:id)).to eq([tool.id])
    ToolCheckout.where(id: checkout.id).update_all(revoked_at: Time.current)
    expect(described_class.new(shop: shop, member: member).eligible_tools).to be_empty
  end

  it "preserves pending access while still requiring explicit prerequisites" do
    member.set(status: "pending")
    prerequisite = create(:tool, shop: shop, reservable: false)
    allowed = insert_tools(1, allow_pending: true).first
    restricted = Tool.new(shop: shop, name: "Restricted", reservable: true, allow_pending: true,
      reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
    Tool.collection.insert_one(restricted.attributes)
    expect(described_class.new(shop: shop, member: member).eligible_tools.map(&:id)).to eq([allowed.id])
  end

  %w[member admin board_member].each do |role|
    it "preserves #{role} eligibility and expiry handling" do
      tool = insert_tools(1).first
      member.set(role: role, expirationTime: 1)
      result = described_class.new(shop: shop, member: member).eligible_tools
      expect(result.map(&:id)).to eq(role == "board_member" ? [tool.id] : [])
      shop.set(disabled: true)
      expect(described_class.new(shop: shop, member: member).eligible_tools).to be_empty
    end
  end
end
