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

    expect(described_class.resolved.map { |channel| [channel.shop.id, channel.id] }).to eq([
      [legacy.id.to_s, "C34567890"],
      [metal.id.to_s, "C23456789"],
      [wood.id.to_s, "C12345678"]
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

  ["#new-shop", "C45678901"].each do |channel|
    [:create, :reassign].each do |operation|
      it "recognizes #{channel} after #{operation} during a Redis outage leaves a stale snapshot" do
        shop = create(:shop, slack_channel: "old-shop")
        snapshot = REDIS.get(AvailableShopCache.data_key)
        allow(REDIS).to receive(:eval).and_raise(Redis::CannotConnectError)
        if operation == :create
          create(:shop, slack_channel: channel)
        else
          shop.update!(slack_channel: channel)
        end
        allow(REDIS).to receive(:eval).and_call_original
        expect(REDIS.get(AvailableShopCache.data_key)).to eq(snapshot)

        identifiers = channel.start_with?("#") ? { channel_name: "NEW-SHOP" } :
          { channel_name: "elsewhere", channel_id: channel }
        expect(AvailableShopCache.find_by_channel(**identifiers)).to be_nil
        expect(described_class.associated?(**identifiers)).to be(true)
        expect(Service::SlackChannelCache).not_to have_received(:lookup)
      end
    end
  end

  it "keeps the cached-hit fast path" do
    create(:shop, slack_channel: "wood-shop")
    create(:shop, slack_channel: "hidden-shop", disabled: true)
    expect(Shop).not_to receive(:where)
    expect(described_class.associated?(channel_name: "wood-shop")).to be(true)
  end

  it "does not associate hidden, blank or unknown channels on a cache miss" do
    create(:shop, slack_channel: "hidden-shop", disabled: true)
    create(:shop, slack_channel: nil)
    expect(described_class.associated?(channel_name: "hidden-shop")).to be(false)
    expect(described_class.associated?(channel_name: "")).to be(false)
    expect(described_class.associated?(channel_name: "unknown")).to be(false)
  end
end
