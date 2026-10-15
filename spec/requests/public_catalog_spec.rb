require "rails_helper"

RSpec.describe "Public catalog", type: :request do
  let!(:shop) { create(:shop, name: "Workshop") }
  let!(:tool) { create(:tool, shop: shop, name: "Saw <script>", description: "<b>Unsafe HTML</b>", notes: "SECRET", gdrive_id: "INTERNAL") }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  before { allow(Rails).to receive(:cache).and_return(cache) }

  it 'shows independent shop and tool outages publicly and revalidates on restoration' do
    tool.update!(out_of_service: true)
    shop.update!(out_of_service: true, out_of_service_note: 'Private maintenance note', ts_oos: 'PRIVATE-RECEIPT')
    ["/shops/#{shop.id}/public.html", "/tools/#{tool.id}/public.html"].each do |path|
      get path
      expect(response.body).to include('Shop out of service', 'Out of service')
      expect(response.body).not_to include('Private maintenance note', 'PRIVATE-RECEIPT')
      etag = response.headers['ETag']
      shop.update!(out_of_service: false)
      get path, headers: { 'If-None-Match' => etag }
      expect(response).to have_http_status(:ok)
      expect(response.headers['ETag']).not_to eq(etag)
      expect(response.body).not_to include('Shop out of service')
      expect(response.body).to include('Out of service')
      shop.update!(out_of_service: true)
    end
    get '/shop/invalid/public.html'
    expect(response.body).to include('Shop out of service')
  end

  it "uses exactly two projected reads per page, even on cache hits" do
    3.times { |n| create(:tool, shop: shop, name: "Tool #{n}") }
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |event| commands << event.command if %w[find aggregate].include?(event.command_name) }
    subscriber.define_singleton_method(:succeeded) { |_event| }
    subscriber.define_singleton_method(:failed) { |_event| }
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    begin
      ["/shops/#{shop.id}/public.html", "/tools/#{tool.id}/public.html"].each do |path|
        2.times do
          commands.clear
          get path
          expect(response).to have_http_status(:ok)
          expect(commands.length).to eq(2)
          expect(commands).to all(include("find", "projection"))
          expect(commands).to all(satisfy { |command| command["projection"].keys.none? { |key| %w[notes gdrive_id users_channel].include?(key) } })
        end
      end
    ensure
      client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
    end
  end

  it "projects public JSON and escapes public HTML without cookies" do
    get "/tools/#{tool.id}/public"
    expect(response.parsed_body.keys).to match_array(%w[id name description open out_of_service wiki_url shop])
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("&lt;script&gt;", "&lt;b&gt;Unsafe HTML&lt;/b&gt;", "Request checkout")
    expect(response.body).not_to include("SECRET", "INTERNAL", "csrf")
    expect(response.headers["Set-Cookie"]).to be_nil
    expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[public max-age=0 s-maxage=0 must-revalidate])
  end

  describe "storage map" do
    it "appears only once the tool has a placed storage location, and follows later moves" do
      get "/tools/#{tool.id}/public.html"
      expect(response.body).not_to include("storage-map")

      cabinet = Location.create!(name: "Secret Cabinet", shop: shop, shape_points: [{ x: 10, y: 10 }, { x: 20, y: 10 }, { x: 20, y: 20 }])
      tool.update!(location_id: cabinet.id)

      get "/tools/#{tool.id}/public.html"
      first_etag = response.headers["ETag"]
      expect(response.body).to include('class="storage-map"', "shopFloorPlans/floor-1", "storage-map-tool", "storage-map-marker")
      expect(response.body).not_to include("Secret Cabinet", "Find where this tool should be stored")

      cabinet.update!(shape_points: [{ x: 60, y: 60 }, { x: 70, y: 60 }, { x: 70, y: 70 }])
      get "/tools/#{tool.id}/public.html"
      expect(response.headers["ETag"]).not_to eq(first_etag)
    end

    it "falls back to a nested location's nearest ancestor geometry, and draws a pin" do
      area = Location.create!(name: "Area", shop: shop, shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }, { x: 50, y: 50 }])
      shelf = Location.create!(name: "Shelf", shop: shop, parent_id: area.id)
      tool.update!(location_id: shelf.id)
      get "/tools/#{tool.id}/public.html"
      expect(response.body).to include("storage-map-tool")

      pin = Location.create!(name: "Pin", shop: shop, x_pct: 30, y_pct: 40)
      tool.update!(location_id: pin.id)
      get "/tools/#{tool.id}/public.html"
      expect(response.body).to include("storage-map-marker")
      expect(response.body).not_to include("storage-map-tool")
    end

    it "draws the floor the tool's own location is on, not the shop's home floor" do
      shop.update!(floor_name: "1")
      upstairs = Location.create!(name: "Upstairs bench", shop: shop, floor_name: "2", x_pct: 30, y_pct: 40)
      Location.create!(name: "Ground area", shop: shop, shape_points: [{ x: 10, y: 10 }, { x: 20, y: 10 }, { x: 20, y: 20 }])
      tool.update!(location_id: upstairs.id)

      get "/tools/#{tool.id}/public.html"
      expect(response.body).to include("shopFloorPlans/floor-2")
      expect(response.body).not_to include("shopFloorPlans/floor-1")
      # the 1st-floor area is not drawn on the 2nd-floor map
      expect(response.body).not_to include("storage-map-area")
    end

    it "draws the tool's marker icon inside the marker, defaulting to the pin" do
      saw = Location.create!(name: "Saw bench", shop: shop, x_pct: 30, y_pct: 40, icon: "saw")
      tool.update!(location_id: saw.id)
      get "/tools/#{tool.id}/public.html"
      expect(response.body).to include('class="storage-map-glyph"', %(d="#{MarkerGlyphs::PATHS['saw']}"))

      plain = Location.create!(name: "Plain spot", shop: shop, x_pct: 30, y_pct: 40)
      tool.update!(location_id: plain.id)
      saw.destroy # the old spot is another pin on the shop's map otherwise, still drawn with its own icon
      get "/tools/#{tool.id}/public.html"
      expect(response.body).to include(%(d="#{MarkerGlyphs::PATHS['pin']}"))
      expect(response.body).not_to include(MarkerGlyphs::PATHS["saw"])
    end

    it "draws the shop's areas in its calendar color and everything nested inside them" do
      allow(Service::GoogleWorkspace).to receive(:cached_calendar_color).and_call_original
      allow(Service::GoogleWorkspace).to receive(:cached_calendar_color).with(shop.color_id).and_return("#123456")
      room = Location.create!(name: "Secret Room", shop: shop, shape_points: [{ x: 10, y: 10 }, { x: 60, y: 10 }, { x: 60, y: 60 }, { x: 10, y: 60 }])
      Location.create!(name: "Secret Cabinet", shop: shop, parent_id: room.id, kind: "cabinet",
                       shape_points: [{ x: 20, y: 20 }, { x: 30, y: 20 }, { x: 30, y: 30 }])
      other_spot = Location.create!(name: "Other spot", shop: shop, parent_id: room.id, x_pct: 40, y_pct: 40)
      create(:tool, shop: shop, name: "Other tool", location_id: other_spot.id)
      mine = Location.create!(name: "My spot", shop: shop, parent_id: room.id, x_pct: 50, y_pct: 50)
      tool.update!(location_id: mine.id)

      get "/tools/#{tool.id}/public.html"
      html = response.body
      expect(html).to include("fill:#123456;fill-opacity:0.3")
      expect(html).to include("fill:#6d4c41;fill-opacity:0.55")
      expect(html).to include('class="storage-map-pin"', "fill:#2e7d32")
      expect(html).to include("storage-map-halo")
      expect(html).not_to include("Secret Room", "Secret Cabinet", "Other spot", "Other tool", "My spot")
    end

    it "never draws another shop's areas, or a disabled tool's spot as a tool spot" do
      other = create(:shop, name: "Other shop")
      Location.create!(name: "Elsewhere", shop: other, shape_points: [{ x: 70, y: 70 }, { x: 90, y: 70 }, { x: 90, y: 90 }])
      held = Location.create!(name: "Held by hidden tool", shop: shop, x_pct: 40, y_pct: 40)
      create(:tool, shop: shop, name: "Hidden tool", location_id: held.id, disabled: true)
      mine = Location.create!(name: "My spot", shop: shop, x_pct: 20, y_pct: 20)
      tool.update!(location_id: mine.id)

      get "/tools/#{tool.id}/public.html"
      expect(response.body).not_to include("storage-map-area")
      expect(response.body).not_to include("fill:#2e7d32")
    end

    it "is omitted when the location has no geometry, and never adds location data to the public JSON" do
      bare = Location.create!(name: "Bare", shop: shop)
      tool.update!(location_id: bare.id)
      get "/tools/#{tool.id}/public.html"
      expect(response.body).not_to include("storage-map")

      pin = Location.create!(name: "Secret Cabinet", shop: shop, x_pct: 10, y_pct: 10)
      tool.update!(location_id: pin.id)
      get "/tools/#{tool.id}/public"
      expect(response.parsed_body.keys).to match_array(%w[id name description open out_of_service wiki_url shop])
    end
  end

  it "lists visible tools alphabetically, including open tools" do
    create(:tool, shop: shop, name: "Alpha", open: true)
    create(:tool, shop: shop, name: "Hidden", disabled: true)
    get "/shops/#{shop.id}/public"
    expect(response.parsed_body.fetch("tools").map { |t| t["name"] }).to eq(["Alpha", tool.name])
    get "/shops/#{shop.id}/public.html"
    expect(response.body).to include("No checkout required")
    expect(response.body).not_to include("Hidden")
  end

  it "uses the HTML cache for 30 minutes and content ETags" do
    expect(cache).to receive(:fetch).with(anything, expires_in: 30.minutes).at_least(:once).and_call_original
    get "/tools/#{tool.id}/public.html"
    etag = response.headers["ETag"]
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    tool.update!(description: "Changed")
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Changed")
    expect(response.headers["ETag"]).not_to eq(etag)
    tool.update!(disabled: true)
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "reflects moves and parent hiding immediately" do
    other = create(:shop, name: "Other")
    get "/shops/#{shop.id}/public.html"
    tool.update!(shop: other)
    get "/shops/#{shop.id}/public.html"
    expect(response.body).not_to include("Saw")
    get "/tools/#{tool.id}/public.html"
    expect(response.body).to include("Other")
    other.update!(disabled: true)
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:not_found)
  end

  it "reuses rendered HTML until the 30 minute expiry" do
    renders = 0
    allow_any_instance_of(PublicCatalogController).to receive(:render_to_string).and_wrap_original do |method, *args|
      renders += 1
      method.call(*args)
    end
    get "/tools/#{tool.id}/public.html"
    get "/tools/#{tool.id}/public.html"
    expect(renders).to eq(1)
    travel 31.minutes do
      get "/tools/#{tool.id}/public.html"
      expect(renders).to eq(2)
    end
  end

  it "renders when Redis fails" do
    allow(cache).to receive(:fetch).and_raise(IOError)
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Request checkout")
  end

  it "returns indistinguishable missing, malformed and hidden responses" do
    tool.update!(disabled: true)
    signatures = ["invalid", BSON::ObjectId.new.to_s, tool.id.to_s].map do |id|
      get "/tools/#{id}/public.html"
      [response.status, response.body, response.headers.values_at("Content-Type", "Cache-Control", "ETag", "Set-Cookie")]
    end
    expect(signatures.uniq.length).to eq(1)
    expect(signatures.first[0]).to eq(404)
    expect(Nokogiri::HTML(signatures.first[1]).at_css("title").text).to eq("Workshops")
  end
end
