require "rails_helper"

RSpec.describe "Public reservation agenda", type: :request do
  let(:zone) { ReservationService::ZONE }
  let(:shop) { create(:shop, name: "Wood Shop") }
  let(:tool) { create(:tool, shop: shop, name: "Planer") }
  let(:member) { create(:member, :current, firstname: "Ada", lastname: "Lovelace") }

  before do
    SlackUser.create!(member: member, slack_id: "U123", name: "ada")
  end

  it "returns active in-progress and upcoming reservations in JSON" do
    travel_to(zone.local(2026, 7, 28, 10, 0)) do
      create(:reservation, member: member, shop: shop, title: "In progress",
        reservation_scope: "tools", tool_ids: [tool.id.to_s],
        start_at: 1.hour.ago, end_at: 1.hour.from_now)
      create(:reservation, member: member, shop: shop, title: "Whole shop",
        reservation_scope: "shop", start_at: 2.hours.from_now, end_at: 3.hours.from_now,
        status: "pending")
      create(:reservation, member: member, shop: shop, title: "Too late",
        start_at: 25.hours.from_now, end_at: 26.hours.from_now)

      get "/reservations/agenda.json", params: { shop: "wood shop", tool: "PLANER" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["shopName"]).to eq("Wood Shop")
      expect(body["toolName"]).to eq("Planer")
      expect(body["reservations"].map { |row| row["title"] })
        .to eq(["In progress", "Whole shop"])
      expect(body["reservations"].first).to include(
        "memberName" => "Ada Lovelace",
        "slackUsername" => "ada",
        "inProgress" => true
      )
      expect(body.dig("upNext", "memberName")).to eq("Ada Lovelace")
      expect(body.dig("upNext", "startAt")).to eq(2.hours.from_now.iso8601)
    end
  end

  it "renders the required HTML headings and excludes in-progress from Up Next" do
    travel_to(zone.local(2026, 7, 28, 10, 0)) do
      create(:reservation, member: member, shop: shop, title: "Current",
        reservation_scope: "tools", tool_ids: [tool.id.to_s],
        start_at: Time.current, end_at: 30.minutes.from_now)
      create(:reservation, member: member, shop: shop, title: "Next",
        reservation_scope: "tools", tool_ids: [tool.id.to_s],
        start_at: 1.hour.from_now, end_at: 2.hours.from_now)

      get "/reservations/agenda", params: { shop: "Wood Shop", tool: "Planer" }

      expect(response.body).to include(
        "<h1>Wood Shop: Planer</h1>",
        "Up Next @ada at 11:00",
        "Current",
        "Next"
      )
    end
  end

  it "falls back to the member's full name for HTML Up Next" do
    member.slack_user.destroy
    travel_to(zone.local(2026, 7, 28, 10, 0)) do
      create(:reservation, member: member, shop: shop, title: "Next",
        reservation_scope: "tools", tool_ids: [tool.id.to_s],
        start_at: 1.hour.from_now, end_at: 2.hours.from_now)

      get "/reservations/agenda", params: { shop: "Wood Shop", tool: "Planer" }

      expect(response.body).to include("Up Next Ada Lovelace at 11:00")
    end
  end

  it "offers only visible reservable tools in the HTML agenda menu" do
    create(:tool, shop: shop, name: "Visible Reservable", reservable: true)
    create(:tool, shop: shop, name: "Hidden Reservable", reservable: true, disabled: true)
    create(:tool, shop: shop, name: "Visible Not Reservable", reservable: false)

    get "/reservations/agenda", params: { shop: shop.name }

    expect(response.body).to include("Select agenda", "Visible Reservable")
    expect(response.body).not_to include("Hidden Reservable", "Visible Not Reservable")
  end

  it "returns format-specific errors for missing or unknown names" do
    get "/reservations/agenda.json"
    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to include("required")

    get "/reservations/agenda", params: { shop: "Unknown" }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Shop was not found.")

    get "/reservations/agenda.json", params: { shop: shop.name, tool: "Unknown" }
    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to include("Tool")
  end

  it "returns 404 without exposing reservations for disabled resources" do
    disabled_shop = create(:shop, name: "Hidden Shop", disabled: true)
    disabled_tool = create(
      :tool,
      shop: shop,
      name: "Hidden Planer",
      disabled: true,
      reservable: true
    )
    create(
      :reservation,
      member: member,
      shop: disabled_shop,
      title: "Private shop reservation",
      start_at: 1.hour.from_now,
      end_at: 2.hours.from_now
    )
    create(
      :reservation,
      member: member,
      shop: shop,
      title: "Private tool reservation",
      reservation_scope: "tools",
      tool_ids: [disabled_tool.id.to_s],
      start_at: 1.hour.from_now,
      end_at: 2.hours.from_now
    )

    get "/reservations/agenda.json", params: { shop: disabled_shop.name }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Shop was not found.")
    expect(response.body).not_to include("Private shop reservation", "Ada Lovelace")

    get "/reservations/agenda", params: { shop: disabled_shop.name }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Shop was not found.")

    get "/reservations/agenda.json", params: {
      shop: shop.name,
      tool: disabled_tool.name
    }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body)
      .to eq("error" => "Tool was not found in Wood Shop.")

    get "/reservations/agenda", params: {
      shop: shop.name,
      tool: disabled_tool.name
    }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Tool was not found in Wood Shop.")
    expect(response.body).not_to include("Private tool reservation", "Ada Lovelace")
  end

  it "uses half-open 24-hour boundaries" do
    travel_to(zone.local(2026, 7, 28, 10, 0)) do
      create(:reservation, member: member, shop: shop, title: "Ends now",
        start_at: 1.hour.ago, end_at: Time.current)
      create(:reservation, member: member, shop: shop, title: "Starts at end",
        start_at: 24.hours.from_now, end_at: 25.hours.from_now)
      create(:reservation, member: member, shop: shop, title: "Crosses end",
        start_at: 23.5.hours.from_now, end_at: 24.5.hours.from_now)

      get "/reservations/agenda.json", params: { shop: shop.name }

      titles = JSON.parse(response.body)["reservations"].map { |row| row["title"] }
      expect(titles).to eq(["Crosses end"])
    end
  end

  it "requires a configured token and is public when it is blank" do
    SystemConfig.set("reservation_token", "secret")

    get "/reservations/agenda.json", params: { shop: shop.name }
    expect(response).to have_http_status(:forbidden)

    get "/reservations/agenda.json", params: { shop: shop.name, token: "secret" }
    expect(response).to have_http_status(:ok)

    SystemConfig.set("reservation_token", "")
    get "/reservations/agenda.json", params: { shop: shop.name }
    expect(response).to have_http_status(:ok)
  end
end
