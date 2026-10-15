require "rails_helper"

RSpec.describe "Slack channel model fields" do
  before do
    allow(Rails.env).to receive(:test?).and_return(false)
    allow(Service::SlackChannelCache).to receive(:lookup)
  end

  it "normalizes a shop channel and opportunistically checks the cache" do
    shop = create(
      :shop,
      slack_channel: "##WOOD-SHOP",
      gdrive_id: " shop-folder "
    )

    expect(shop.slack_channel).to eq("#wood-shop")
    expect(shop.gdrive_id).to eq("shop-folder")
    expect(Service::SlackChannelCache).to have_received(:lookup).with(
      "#wood-shop",
      refresh_on_miss: true
    )
  end

  it "normalizes both tool channels and checks changed values" do
    tool = create(:tool)
    tool.update!(
      announce_channel: "#SHOP-ANNOUNCE",
      users_channel: "##TOOL-USERS",
      gdrive_id: " tool-folder "
    )

    expect(tool.announce_channel).to eq("#shop-announce")
    expect(tool.users_channel).to eq("#tool-users")
    expect(tool.gdrive_id).to eq("tool-folder")
    expect(Service::SlackChannelCache).to have_received(:lookup).with(
      "#shop-announce",
      refresh_on_miss: true
    )
    expect(Service::SlackChannelCache).to have_received(:lookup).with(
      "#tool-users",
      refresh_on_miss: true
    )
  end
end
