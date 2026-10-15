require "rails_helper"

RSpec.describe "Public QR codes and workshop directory", type: :request do
  let!(:shop) { create(:shop, name: "Woodworking") }
  let!(:tool) { create(:tool, shop: shop, name: "Saw <test>", wiki_url: "https://wiki.example.test/saw") }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    Shortcode.create_indexes
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set).and_return("OK")
    allow(Rails).to receive(:cache).and_return(cache)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("portal.example.org")
  end

  it "encodes working canonical HTTPS links in public SVGs without cookies" do
    { "tool" => tool, "shop" => shop }.each do |kind, record|
      target = "https://portal.example.org/api/#{kind}/#{record.id}/public.html"
      expect(RQRCode::QRCode).to receive(:new).with(ShortUrl.allocate(target)[:short_url], mode: :alphanumeric).and_call_original
      get "/#{kind}/#{record.id}/public.svg"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/svg+xml")
      expect(Nokogiri::XML(response.body).root.name).to eq("svg")
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[public max-age=259200 s-maxage=259200])
      get URI(target).request_uri
      expect(response).to have_http_status(:ok)
    end
  end

  [
    ["https://portal.example.org/", "https://portal.example.org"],
    ["portal.example.org:8443", "https://portal.example.org:8443"]
  ].each do |domain, base_url|
    it "normalizes QR destinations for #{domain}" do
      allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return(domain)
      %w[ENVIRONMENT RAILS_ENV RACK_ENV].each do |key|
        allow(ENV).to receive(:[]).with(key).and_return("test")
      end
      { "tool" => tool, "shop" => shop }.each do |kind, record|
        expect(RQRCode::QRCode).to receive(:new)
          .with(ShortUrl.allocate("#{base_url}/api/#{kind}/#{record.id}/public.html")[:short_url], mode: :alphanumeric).and_call_original
        get "/#{kind}/#{record.id}/public.svg"
        expect(response).to have_http_status(:ok)
      end
    end
  end

  it "uses the request host for public QR codes when APP_DOMAIN is blank" do
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("  ")
    host! "www.example.com:8443"
    expect(Rails.logger).to receive(:warn).with(/APP_DOMAIN missing or blank/).at_least(:once)
    expect(RQRCode::QRCode).to receive(:new).with(%r{\AHTTPS://WWW.EXAMPLE.COM:8443/L[2-9A-Z]{10}\z}, mode: :alphanumeric).and_call_original
    get "/shop/#{shop.id}/public.svg"
    expect(response.status).to eq(200)
    expect(response.headers["Set-Cookie"]).to be_nil
    expect(Shortcode.first.target_url).to eq("/api/shop/#{shop.id}/public.html")
  end

  ["localhost", "http://localhost:3035/", "127.0.0.1", "[::1]"].each do |domain|
    it "never encodes a QR code for #{domain}" do
      allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return(domain)
      expect(RQRCode::QRCode).not_to receive(:new)
      get "/shop/#{shop.id}/public.svg"
      expect(response.status).to eq(503)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(Shortcode.count).to eq(0)
    end
  end

  it "caches QR rendering for 30 minutes and handles ETags after visibility checks" do
    expect(RQRCode::QRCode).to receive(:new).twice.and_call_original
    get "/tool/#{tool.id}/public.svg"
    etag = response.headers["ETag"]
    original = response.body
    get "/tool/#{tool.id}/public.svg"
    expect(response.body).to eq(original)
    get "/tool/#{tool.id}/public.svg", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    travel 31.minutes do
      get "/tool/#{tool.id}/public.svg"
      expect(response).to have_http_status(:ok)
    end
    shop.update!(disabled: true)
    get "/tool/#{tool.id}/public.svg", headers: { "If-None-Match" => etag }
    expect(response.status).to eq(404)
    expect(response.body).to eq("Not Found")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "renders a QR when Redis fails and changes it when APP_DOMAIN changes" do
    allow(cache).to receive(:fetch).and_raise(IOError)
    get "/shop/#{shop.id}/public.svg"
    expect(response).to have_http_status(:ok)
    original_etag = response.headers["ETag"]
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("new.example.org")
    expect(RQRCode::QRCode).to receive(:new).with(ShortUrl.allocate("/api/shop/#{shop.id}/public.html")[:short_url], mode: :alphanumeric).and_call_original
    get "/shop/#{shop.id}/public.svg"
    expect(response.headers["ETag"]).not_to eq(original_etag)
  end

  it "rejects hidden, malformed, missing and orphaned QR resources identically" do
    tool.update!(disabled: true)
    shop.update!(disabled: true)
    %w[tool shop].each do |kind|
      ["bad", BSON::ObjectId.new.to_s, (kind == "tool" ? tool : shop).id.to_s].each do |id|
        get "/#{kind}/#{id}/public.svg"
        expect(response.status).to eq(404)
        expect(response.body).to eq("Not Found")
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect(response.headers["Set-Cookie"]).to be_nil
      end
    end
    tool.set(disabled: false, shop_id: BSON::ObjectId.new)
    get "/tool/#{tool.id}/public.svg"
    expect(response.status).to eq(404)
  end

  it "shows a sorted, escaped directory for all unavailable HTML routes" do
    alpha = create(:shop, name: "alpha <script>")
    create(:shop, name: "Hidden", disabled: true)
    tool.update!(disabled: true)
    ["/tool/bad/public.html", "/api/shop/#{BSON::ObjectId.new}/public.html", "/tools/#{tool.id}/public.html"].each do |url|
      get url
      html = Nokogiri::HTML(response.body)
      expect(response.status).to eq(404)
      expect(html.at_css("title").text).to eq("Workshops")
      expect(html.css("main li a").map(&:text)).to eq([alpha.name, shop.name])
      expect(html.css("main li a").map { |a| a["href"] }).to eq(["/shop/#{alpha.id}/public.html", "/shop/#{shop.id}/public.html"])
      expect(response.body).to include("&lt;script&gt;")
      expect(response.body).not_to include("Hidden", tool.name)
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(html.css("footer a").length).to eq(5)
    end
    get "/tools/#{tool.id}/public.json"
    expect(response.body).to eq("Not Found")
  end

  it "embeds synchronized resource emails from projected tool and shop reads" do
    shop.update!(google_resource_id: "R1", resource_email: "shop-calendar@resource.calendar.google.com")
    tool.update!(google_resource_id: "R2", resource_email: "tool-calendar@resource.calendar.google.com")
    get "/tool/#{tool.id}/public.html"
    calendars = -> { Nokogiri::HTML(response.body).css("iframe").map { |frame| URI.decode_www_form(URI(frame["src"]).query).to_h["src"] } }
    expect(calendars.call).to eq(%w[tool-calendar@resource.calendar.google.com shop-calendar@resource.calendar.google.com])
    etag = response.headers["ETag"]
    tool.update!(resource_email: "updated-calendar@resource.calendar.google.com")
    get "/tool/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(calendars.call.first).to eq("updated-calendar@resource.calendar.google.com")
    get "/shop/#{shop.id}/public.html"
    expect(calendars.call).to eq([shop.resource_email])
    get "/tool/#{tool.id}/public.json"
    expect(response.body).not_to include("resource_email", "resource.calendar.google.com", "google_resource_id")
    get "/shop/#{shop.id}/public.json"
    expect(response.body).not_to include("resource_email", "resource.calendar.google.com", "google_resource_id")
  end

  it "links the tool title to its wiki and embeds only configured resource calendars" do
    shop.update!(google_resource_id: "shop-calendar")
    tool.update!(google_resource_id: "tool-calendar@resource.calendar.google.com")
    get "/tool/#{tool.id}/public.html"
    html = Nokogiri::HTML(response.body)
    expect(html.at_css("h1 a")["href"]).to eq(tool.wiki_url)
    expect(html.at_css("h1 a").text).to eq(tool.name)
    calendar_ids = html.css("iframe").map { |frame| URI.decode_www_form(URI(frame["src"]).query).to_h["src"] }
    expect(calendar_ids).to eq(%w[tool-calendar@resource.calendar.google.com shop-calendar@resource.calendar.google.com])
    expect(html.css("iframe").all? { |frame| frame["title"].present? }).to eq(true)
    expect(html.css("footer a").map { |a| a["aria-label"] }).to eq(["Public Home", "Public Wiki", "Event Calendar", "Chat with us on Slack", "Contact us via Email"])
    etag = response.headers["ETag"]
    tool.update!(google_resource_id: nil)
    get "/tool/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response.status).to eq(200)
    expect(Nokogiri::HTML(response.body).css("iframe").length).to eq(1)
    get "/shop/#{shop.id}/public.html"
    expect(Nokogiri::HTML(response.body).css("iframe").length).to eq(1)
    get "/tool/#{tool.id}/public.json"
    expect(response.body).not_to include("calendar", "google_resource_id")
  end
end
