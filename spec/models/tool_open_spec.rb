require "rails_helper"
RSpec.describe Tool do
  it "defaults absent and null legacy open values to false" do
    tool = create(:tool)
    Tool.collection.find(_id: tool.id).update_one("$unset" => { "open" => "" })
    expect(tool.reload.open).to eq(false)
    Tool.collection.find(_id: tool.id).update_one("$set" => { "open" => nil })
    expect(tool.reload.open).to eq(false)
  end

  it "omits only the automatic prerequisite" do
    tool = Tool.new(open: true)
    other_id = BSON::ObjectId.new.to_s
    tool.reservation_prerequisite_tool_ids = [other_id]
    expect(tool.effective_reservation_prerequisite_ids).to eq([other_id])
    tool.reservation_prerequisite_tool_ids << tool.id.to_s
    expect(tool.effective_reservation_prerequisite_ids).to include(tool.id.to_s, other_id)
  end

  it "preserves administrative grants and existing request approval" do
    allow(REDIS).to receive(:set).and_return(true)
    tool = create(:tool)
    member = create(:member)
    request = ToolCheckoutRequest.create!(tool: tool, member: member)
    tool.update!(open: true)
    checkout = create(:tool_checkout, tool: tool, member: member)
    expect(checkout.persisted?).to eq(true)
    expect(request.reload.status).to eq("closed")
    expect(request.checked_out_id).to eq(checkout.id)
  end

  it "rejects only new requests, preserving updates to history" do
    tool = create(:tool)
    member = create(:member)
    request = ToolCheckoutRequest.create!(tool: tool, member: member)
    tool.update!(open: true)
    expect(ToolCheckoutRequest.new(tool: tool, member: member)).not_to be_valid
    expect { request.update!(status: "closed") }.not_to raise_error
  end
end
