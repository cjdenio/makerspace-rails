require "rails_helper"

RSpec.describe Service::ShopSlackChannels do
  before do
    allow(Service::SlackChannelCache).to receive(:lookup).and_return(nil)
  end

  it "resolves only enabled shops with assigned public channels and normalizes configured names" do
    wood = create(:shop, name: "Wood Shop", slack_channel: "#WOOD-SHOP")
    metal = create(:shop, name: "Metal Shop", slack_channel: "metal-shop")
    legacy = create(:shop, name: "Legacy Shop", slack_channel: "legacy-shop")
    legacy.set(disabled: nil)
    create(:shop, name: "Disabled Shop", disabled: true, slack_channel: "disabled-shop")
    create(:shop, name: "Unassigned Shop", slack_channel: nil)
    create(:shop, name: "Private Shop", slack_channel: "private-shop")
    create(:shop, name: "Unresolved Shop", slack_channel: "missing-shop")

    allow(Service::SlackChannelCache).to receive(:lookup).with("#wood-shop")
      .and_return(id: "C12345678", name: "#wood-shop")
    allow(Service::SlackChannelCache).to receive(:lookup).with("#metal-shop")
      .and_return(id: "C23456789", name: "#metal-shop")
    allow(Service::SlackChannelCache).to receive(:lookup).with("#legacy-shop")
      .and_return(id: "C34567890", name: "#legacy-shop")
    allow(Service::SlackChannelCache).to receive(:lookup).with("#private-shop")
      .and_return(id: "G34567890", name: "#private-shop")

    expect(described_class.resolved.map { |channel| [channel.shop, channel.id] }).to eq([
      [legacy, "C34567890"],
      [metal, "C23456789"],
      [wood, "C12345678"]
    ])
    expect(Service::SlackChannelCache).not_to have_received(:lookup).with("#disabled-shop")
  end

  it "recognizes configured channels by normalized name or channel id" do
    create(:shop, slack_channel: "#wood-shop")
    create(:shop, slack_channel: "C23456789")

    expect(described_class.associated?(channel_name: "WOOD-SHOP")).to be(true)
    expect(described_class.associated?(channel_name: "elsewhere", channel_id: "C23456789")).to be(true)
    expect(described_class.associated?(channel_name: "elsewhere")).to be(false)
  end

  it "returns an empty list when cache lookups are unavailable" do
    create(:shop, slack_channel: "wood-shop")
    allow(Service::SlackChannelCache).to receive(:lookup).and_raise(Redis::CannotConnectError)

    expect(described_class.resolved).to eq([])
  end
end
