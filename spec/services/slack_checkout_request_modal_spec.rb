require "rails_helper"

RSpec.describe SlackCheckoutRequestModal do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, name: "Woodshop") }

  it "builds a required tool selector and an optional 128-character note" do
    tool = create(:tool, shop: shop, name: "Bandsaw", open: false)

    view = described_class.build(shop, member)
    tool_block = view[:blocks].find { |block| block[:block_id] == "tool" }
    note_block = view[:blocks].find { |block| block[:block_id] == "note" }

    expect(view).to include(callback_id: "checkout_request_submit")
    expect(tool_block).not_to include(optional: true)
    expect(tool_block.dig(:element, :type)).to eq("static_select")
    expect(tool_block.dig(:element, :options)).to include(hash_including(value: tool.id.to_s))
    expect(note_block).to include(optional: true)
    expect(note_block.dig(:element, :max_length)).to eq(128)
  end

  it "does not offer tools the member already has checked out" do
    tool = create(:tool, shop: shop, open: false)
    create(:tool_checkout, member: member, tool: tool)

    expect { described_class.build(shop, member) }
      .to raise_error(Error::UnprocessableEntity, "This shop has no tools you can request")
  end
end
