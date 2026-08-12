require "rails_helper"

RSpec.describe "Workshops", type: :request do
  let(:member) { create(:member, :current) }
  let!(:shop) { create(:shop, name: "Wood Shop") }
  let!(:disabled_shop) { create(:shop, name: "Closed Shop", disabled: true) }
  let!(:visible_tool) { create(:tool, shop: shop, name: "Planer") }
  let!(:checked_out_hidden_tool) do
    create(:tool, shop: shop, name: "Hidden Saw", disabled: true)
  end
  let!(:other_hidden_tool) do
    create(:tool, shop: shop, name: "Hidden Lathe", disabled: true)
  end

  before do
    allow(Service::SlackChannelCache).to receive(:fetch).and_return(nil)
    create(:tool_checkout, member: member, tool: checked_out_hidden_tool)
    sign_in member
  end

  it "hides disabled shops and shows hidden tools only when checked out" do
    get "/api/workshops"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["canAddShop"]).to be(false)
    expect(body["workshops"].map { |row| row["name"] }).to eq(["Wood Shop"])
    tool_names = body["workshops"].first["tools"].map { |row| row["name"] }
    expect(tool_names).to contain_exactly("Planer", "Hidden Saw")
  end

  it "shows disabled shops and all hidden tools to admins" do
    sign_out member
    sign_in create(:member, :admin, :current)

    get "/api/workshops"

    body = JSON.parse(response.body)
    expect(body["canAddShop"]).to be(true)
    expect(body["workshops"].map { |row| row["name"] })
      .to contain_exactly("Closed Shop", "Wood Shop")
    woodshop = body["workshops"].find { |row| row["name"] == "Wood Shop" }
    expect(woodshop["tools"].map { |row| row["name"] })
      .to contain_exactly("Planer", "Hidden Saw", "Hidden Lathe")
  end

  it "only offers reservations when the current member meets resource prerequisites" do
    shop.update!(reservable: false)
    visible_tool.update!(reservable: true)

    get "/api/workshops"
    expect(JSON.parse(response.body).dig("workshops", 0, "reservationsAvailable"))
      .to be(false)

    create(:tool_checkout, member: member, tool: visible_tool)
    get "/api/workshops"
    expect(JSON.parse(response.body).dig("workshops", 0, "reservationsAvailable"))
      .to be(true)
  end

  it "uses allow_pending for pending checkout and reservation actions" do
    member.update!(status: "pending", expirationTime: nil)
    shop.update!(reservable: true)
    visible_tool.update!(reservable: true, allow_pending: false)
    pending_tool = create(
      :tool,
      shop: shop,
      name: "Orientation",
      reservable: true,
      allow_pending: true
    )

    get "/api/workshops"

    woodshop = JSON.parse(response.body).fetch("workshops")
      .find { |row| row["id"] == shop.id.to_s }
    tools = woodshop.fetch("tools").index_by { |tool| tool.fetch("id") }
    expect(tools.fetch(pending_tool.id.to_s)).to include(
      "checkoutRequestable" => true,
      "reservationAvailable" => true
    )
    expect(tools.fetch(visible_tool.id.to_s)).to include(
      "checkoutRequestable" => false,
      "reservationAvailable" => false
    )
    expect(woodshop.fetch("reservationsAvailable")).to be(true)
  end

  it "does not let a future expiration bypass pending tool restrictions" do
    member.update!(
      status: "pending",
      expirationTime: 1.month.from_now.to_i * 1000
    )
    shop.update!(reservable: true)
    visible_tool.update!(reservable: true, allow_pending: false)

    get "/api/workshops"

    woodshop = JSON.parse(response.body).fetch("workshops")
      .find { |row| row["id"] == shop.id.to_s }
    tool = woodshop.fetch("tools")
      .find { |row| row["id"] == visible_tool.id.to_s }
    expect(tool).to include(
      "checkoutRequestable" => false,
      "reservationAvailable" => false
    )
    expect(woodshop.fetch("reservationsAvailable")).to be(false)
  end

  it "includes cached Slack details, GDrive links, checkout state, requests, and upcoming events" do
    shop.update!(
      slack_channel: "wood-shop",
      gdrive_id: "shop-folder"
    )
    visible_tool.update!(
      users_channel: "planer-users",
      gdrive_id: "tool-folder"
    )
    checkout = create(:tool_checkout, member: member, tool: visible_tool)
    ToolCheckoutRequest.create!(
      member: member,
      tool: other_hidden_tool,
      note: "Please train me",
      status: "open"
    )
    VolunteerEvent.create!(
      title: "Shop Cleanup",
      description: "Sweep and organize",
      credit_value: 1.5,
      event_date: Date.current + 2.days,
      shop_id: shop.id,
      created_by_id: member.id
    )
    allow(Service::SlackChannelCache).to receive(:fetch)
      .with("wood-shop")
      .and_return(
        id: "C123",
        name: "wood-shop",
        topic: "Woodworking",
        purpose: "Coordinate the shop"
      )
    allow(Service::SlackChannelCache).to receive(:fetch)
      .with("planer-users")
      .and_return(
        id: "C456",
        name: "planer-users",
        topic: "",
        purpose: ""
      )

    get "/api/workshops"

    woodshop = JSON.parse(response.body)["workshops"]
      .find { |row| row["id"] == shop.id.to_s }
    expect(woodshop).to include(
      "gdriveId" => "shop-folder",
      "slackChannelDetails" => include(
        "id" => "C123",
        "topic" => "Woodworking",
        "purpose" => "Coordinate the shop"
      )
    )
    planer = woodshop["tools"].find { |row| row["id"] == visible_tool.id.to_s }
    expect(planer).to include(
      "gdriveId" => "tool-folder",
      "checkout" => include("id" => checkout.id.to_s, "active" => true),
      "usersChannelDetails" => include("id" => "C456")
    )
    expect(woodshop["upcomingVolunteerEvents"].first).to include(
      "title" => "Shop Cleanup",
      "creditValue" => 1.5
    )
  end

  it "only includes upcoming volunteer events the viewer is eligible for" do
    eligible_event = VolunteerEvent.create!(
      title: "General Cleanup",
      description: "Clean the shop",
      credit_value: 1,
      event_date: Date.current + 1.day,
      shop_id: shop.id,
      created_by_id: member.id
    )
    restricted_event = VolunteerEvent.create!(
      title: "Planer Maintenance",
      description: "Maintain the planer",
      credit_value: 1,
      event_date: Date.current + 2.days,
      shop_id: shop.id,
      prerequisite_tool_ids: [visible_tool.id.to_s],
      created_by_id: member.id
    )

    get "/api/workshops"

    events = JSON.parse(response.body).dig(
      "workshops", 0, "upcomingVolunteerEvents"
    )
    expect(events.map { |event| event.fetch("id") })
      .to contain_exactly(eligible_event.id.to_s)

    create(:tool_checkout, member: member, tool: visible_tool)
    get "/api/workshops"

    events = JSON.parse(response.body).dig(
      "workshops", 0, "upcomingVolunteerEvents"
    )
    expect(events.map { |event| event.fetch("id") })
      .to contain_exactly(eligible_event.id.to_s, restricted_event.id.to_s)
  end

  it "sorts unmet visible bounty prerequisites last and hides unmet hidden prerequisites" do
    visible_task = VolunteerTask.create!(
      title: "General cleanup",
      description: "Clean benches",
      credit_value: 1,
      shop_id: shop.id,
      prerequisite_tool_ids: [],
      created_by_id: member.id,
      status: "available"
    )
    unmet_task = VolunteerTask.create!(
      title: "Planer cleanup",
      description: "Clean the planer",
      credit_value: 1,
      shop_id: shop.id,
      prerequisite_tool_ids: [visible_tool.id.to_s],
      created_by_id: member.id,
      status: "available"
    )
    VolunteerTask.create!(
      title: "Hidden maintenance",
      description: "Maintain hidden equipment",
      credit_value: 1,
      shop_id: shop.id,
      prerequisite_tool_ids: [other_hidden_tool.id.to_s],
      created_by_id: member.id,
      status: "available"
    )

    get "/api/workshops"

    tasks = JSON.parse(response.body).dig("workshops", 0, "volunteerTasks")
    expect(tasks.map { |task| task["id"] })
      .to eq([visible_task.id.to_s, unmet_task.id.to_s])
    expect(tasks.last).to include(
      "eligible" => false,
      "missingPrerequisiteToolNames" => [visible_tool.name]
    )
  end
end
