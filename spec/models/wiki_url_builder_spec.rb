require "rails_helper"

RSpec.describe WikiUrlBuilder do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WIKI_URL")
      .and_return("https://wiki.example.test/base/")
  end

  it "builds lowercase punctuation-normalized shop and tool URLs" do
    expect(described_class.shop_url("Metal & Machine Shop!"))
      .to eq("https://wiki.example.test/base/workshops/metal-machine-shop")
    expect(described_class.tool_url("Metal & Machine Shop!", "MIG Welder #2"))
      .to eq("https://wiki.example.test/base/workshops/metal-machine-shop#mig-welder-2")
  end

  it "uses explicit model URLs and generates defaults when they are blank" do
    shop = Shop.new(name: "Wood Shop", wiki_url: "")
    tool = Tool.new(name: "Table Saw", shop: shop)

    expect(shop.effective_wiki_url)
      .to eq("https://wiki.example.test/base/workshops/wood-shop")
    expect(tool.effective_wiki_url)
      .to eq("https://wiki.example.test/base/workshops/wood-shop#table-saw")

    shop.wiki_url = "https://docs.example.test/wood"
    tool.wiki_url = "https://docs.example.test/saw"
    expect(shop.effective_wiki_url).to eq("https://docs.example.test/wood")
    expect(tool.effective_wiki_url).to eq("https://docs.example.test/saw")
  end
end
