require "rails_helper"

RSpec.describe "Short URLs", type: :request do
  let!(:shop) { create(:shop, name: "Woodworking") }
  let!(:tool) { create(:tool, shop: shop) }
  let(:path) { "/api/tool/#{tool.id}/public.html" }
  let(:cache) { {} }
  before do
    Shortcode.create_indexes
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("members.example.org")
    allow(REDIS).to receive(:get) { |key| cache[key] }
    allow(REDIS).to receive(:set) { |key, value, **options| expect(options[:ex]).to eq(86_400); cache[key] = value }
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it "allocates a deterministic permanent code and serves public HTML internally" do
    result = ShortUrl.allocate(path)
    expected = ShortUrl.encode(Digest::SHA256.hexdigest("https://members.example.org#{path}").to_i(16))
    expect(result).to eq(code: expected, short_url: "HTTPS://MEMBERS.EXAMPLE.ORG/L#{expected}")
    expect(ShortUrl.allocate(path)).to eq(result)
    expect(Shortcode.count).to eq(1)
    get "/L#{expected}?ignored=yes"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Location"]).to be_nil
    expect(response.headers["Set-Cookie"]).to be_nil
    expect(response.body).to include(tool.name)
    etag = response.headers["ETag"]
    get "/L#{expected}", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    tool.update!(disabled: true)
    get "/L#{expected}", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  [nil, "", " \t "].each do |domain|
    it "uses the request authority when APP_DOMAIN is #{domain.inspect}" do
      allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return(domain)
      host! "www.example.com:8443"
      sign_in create(:member)
      expect(Rails.logger).to receive(:warn).with(/APP_DOMAIN missing or blank/).at_least(:once)
      post "/api/shortcodes", params: { target_url: path }, as: :json
      expect(response.status).to eq(200)
      code = response.parsed_body.fetch("code")
      expect(response.parsed_body["short_url"]).to eq("HTTPS://WWW.EXAMPLE.COM:8443/L#{code}")
      expect(Shortcode.find_by(code: code).target_url).to eq(path)
      expect(cache["shortcodes:v1:#{code}"]).to eq(path)
      get "/L#{code}"
      expect(response.status).to eq(200)
      expect(response.headers["Location"]).to be_nil
      cache.clear
      get "/L#{code}"
      expect(response.status).to eq(200)
    end
  end

  it "uses APP_DOMAIN ahead of the client host" do
    expect(ShortUrl.base_url(fallback_host: "other.example.org")).to eq("https://members.example.org")
  end

  it "rejects missing, malformed and local fallback authorities before allocation" do
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("")
    [nil, "", "localhost", "LOCALHOST.:3000", "sub.localhost", "127.0.0.1:3000", "[::1]",
     "[::ffff:127.0.0.1]", "0.0.0.0", "2130706433", "user@scan.example.org", "https://scan.example.org",
     "scan.example.org/path", "scan.example.org?x=1", "scan.example.org#x", "scan.example.org:99999",
     "scan.example.org\r\nHost: evil.org"].each do |host|
      expect { ShortUrl.base_url(fallback_host: host) }.to raise_error(ShortUrl::Unavailable)
    end
    expect { ShortUrl.allocate(path) }.to raise_error(ShortUrl::Unavailable)
    expect(Shortcode.count).to eq(0)
    expect(cache).to be_empty
  end

  it "returns an uncached 503 instead of allocating on localhost" do
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("")
    host! "localhost"
    sign_in create(:member)
    post "/api/shortcodes", params: { target_url: path }, as: :json
    expect(response.status).to eq(503)
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    expect(Shortcode.count).to eq(0)
    expect(cache).to be_empty
  end

  it "stores only the path for absolute and relative targets" do
    result = ShortUrl.allocate("https://members.example.org#{path}")
    expect(Shortcode.find_by(code: result[:code]).target_url).to eq(path)
    expect(cache["shortcodes:v1:#{result[:code]}"]).to eq(path)
    expect(ShortUrl.allocate(path)).to eq(result)
    expect(Shortcode.count).to eq(1)
  end

  it "rebuilds path targets using the current origin on warm and cold resolution" do
    code = ShortUrl.allocate(path)[:code]
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("https://new.example.org:8443")
    expect(Shortcode).not_to receive(:where)
    expect(ShortUrl.resolve(code)).to eq("https://new.example.org:8443#{path}")
    RSpec::Mocks.space.proxy_for(Shortcode).reset
    cache.clear
    expect(ShortUrl.resolve(code)).to eq("https://new.example.org:8443#{path}")
    expect(cache["shortcodes:v1:#{code}"]).to eq(path)
    expect(ShortUrl.allocate(path)).to eq(code: code, short_url: "HTTPS://NEW.EXAMPLE.ORG:8443/L#{code}")
    expect(Shortcode.count).to eq(1)
    get "/L#{code}"
    expect(response.status).to eq(200)
    expect(response.headers["Location"]).to be_nil
  end

  it "reuses legacy absolute Mongo mappings and caches their paths without changing printed codes" do
    code = "23456789AB"
    record = Shortcode.create!(code: code, target_url: "https://members.example.org#{path}")
    expect(ShortUrl.resolve(code)).to eq("https://members.example.org#{path}")
    expect(cache["shortcodes:v1:#{code}"]).to eq(path)
    expect(ShortUrl.allocate(path)[:code]).to eq(code)
    expect(Shortcode.count).to eq(1)
    expect(record.reload.target_url).to eq("https://members.example.org#{path}")
  end

  it "continues reading valid legacy absolute cache entries without Mongo" do
    cache["shortcodes:v1:23456789AB"] = "https://members.example.org#{path}"
    expect(Shortcode).not_to receive(:where)
    expect(ShortUrl.resolve("23456789AB")).to eq("https://members.example.org#{path}")
  end

  it "resolves cache hits without Mongo and recovers from misses and malformed entries" do
    code = ShortUrl.allocate(path)[:code]
    expect(Shortcode).not_to receive(:where)
    expect(ShortUrl.resolve(code)).to end_with(path)
  end

  it "recovers from cache eviction, invalid values and Redis errors" do
    code = ShortUrl.allocate(path)[:code]
    cache.clear
    expect(ShortUrl.resolve(code)).to end_with(path)
    expect(cache["shortcodes:v1:#{code}"]).to eq(path)
    cache["shortcodes:v1:#{code}"] = "https://evil.test/"
    expect(ShortUrl.resolve(code)).to end_with(path)
    allow(REDIS).to receive(:get).and_raise(Redis::BaseError)
    allow(REDIS).to receive(:set).and_raise(Redis::BaseError)
    expect(ShortUrl.resolve(code)).to end_with(path)
    expect(ShortUrl.allocate(path)[:code]).to eq(code)
  end

  it "increments collisions with carry and wraps within the alphabet" do
    expect(ShortUrl.encode(33)).to eq("222222222Z")
    expect(ShortUrl.encode(34)).to eq("2222222232")
    expect(ShortUrl.encode(ShortUrl::SPACE)).to eq("2222222222")
    first = ShortUrl.allocate(path)
    allow(Digest::SHA256).to receive(:hexdigest).and_return(Digest::SHA256.hexdigest("https://members.example.org#{path}"))
    other = ShortUrl.allocate("/api/shop/#{shop.id}/public.html")
    expect(other[:code]).not_to eq(first[:code])
    expect(Shortcode.count).to eq(2)
  end

  it "allocates the same target concurrently once" do
    results = 6.times.map { Thread.new { ShortUrl.allocate(path) } }.map(&:value)
    expect(results.map { |r| r[:code] }.uniq.length).to eq(1)
    expect(Shortcode.count).to eq(1)
  end

  it "arbitrates concurrent collisions for different targets" do
    allow(Digest::SHA256).to receive(:hexdigest).and_return("0")
    targets = [path, "/api/shop/#{shop.id}/public.html"]
    results = targets.map { |target| Thread.new { ShortUrl.allocate(target) } }.map(&:value)
    expect(results.map { |r| r[:code] }.sort).to eq(%w[2222222222 2222222223])
    expect(Shortcode.count).to eq(2)
    targets.each { |target| expect(ShortUrl.allocate(target)[:code]).to eq(Shortcode.find_by(target_url: target).code) }
  end

  it "refuses allocation before unique indexes are verified" do
    ShortUrl.instance_variable_set(:@indexes_verified, false)
    allow(Shortcode).to receive(:collection).and_return(double(indexes: double(to_a: [{ "key" => { "_id" => 1 }, "name" => "_id_" }])))
    expect { ShortUrl.allocate(path) }.to raise_error(ShortUrl::Unavailable)
    expect(cache).to be_empty
  ensure
    ShortUrl.instance_variable_set(:@indexes_verified, false)
  end

  it "serves HEAD and rejects malformed codes without cookies" do
    code = ShortUrl.allocate(path)[:code]
    head "/L#{code}"
    expect(response.status).to eq(200)
    expect(response.body).to be_empty
    ["/L#{code}/extra", "/l#{code.downcase}", "/L0123456789"].each do |url|
      get url
      expect(response.status).to eq(404)
      expect(response.headers["Set-Cookie"]).to be_nil
    end
    head "/LINVALID"
    expect(response.body).to be_empty
    expect(response.status).to eq(404)
  end

  it "rejects unsupported targets" do
    ["https://evil.test#{path}", "//evil.test#{path}", "#{path}?x=1", "#{path}#x", "/L23456789AB", "/members/abc", "https://user@members.example.org#{path}"].each do |value|
      expect { ShortUrl.allocate(value) }.to raise_error(ShortUrl::InvalidTarget)
    end
  end

  it "returns uncached generic failures for unknown codes and database outages" do
    get "/L23456789AB"
    expect(response.status).to eq(404)
    expect(response.body).to eq("Not Found")
    get "/LINVALID"
    expect(response.status).to eq(404)
    allow(Shortcode).to receive(:where).and_raise(Mongo::Error.new("offline"))
    get "/L23456789AB"
    expect(response.status).to eq(503)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect { ShortUrl.allocate(path) }.to raise_error(ShortUrl::Unavailable)
    expect(cache).to be_empty
  end

  %w[shop tool rental].each do |kind|
    it "returns private 503 when #{kind} visibility storage fails" do
      sign_in create(:member)
      target = kind == "rental" ? "/rentals/spots/#{BSON::ObjectId.new}" : "/api/#{kind}/#{tool.id}/public.html"
      if kind == "rental"
        allow(RentalSpot).to receive(:where).and_raise(Mongo::Error.new("offline"))
      else
        allow(PublicCatalog).to receive(kind.to_sym).and_raise(Mongo::Error.new("offline"))
      end
      expect(ShortUrl).not_to receive(:allocate)
      post "/api/shortcodes", params: { target_url: target }, as: :json
      expect(response.status).to eq(503)
      expect(response.parsed_body).to eq("error" => "Short URL unavailable")
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
    end
  end

  it "requires authentication and checks visibility on allocation" do
    post "/api/shortcodes", params: { target_url: path }, as: :json
    expect(response.status).to eq(401)
    sign_in create(:member)
    post "/api/shortcodes", params: { target_url: path }, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body["short_url"]).to match(%r{\AHTTPS://MEMBERS.EXAMPLE.ORG/L[2-9A-Z]{10}\z})
    tool.update!(disabled: true)
    post "/api/shortcodes", params: { target_url: path }, as: :json
    expect(response.status).to eq(404)
    expect(response.body).to eq("Not Found")
    expect(Shortcode.count).to eq(1)
  end

  it "retains the real checkout destination through authentication" do
    checkout = "/tools/#{tool.id}/request-checkout"
    code = ShortUrl.allocate(checkout)[:code]
    get "/L#{code}"
    expect(response.status).to eq(302)
    expect(response.headers["Location"]).to include(ERB::Util.url_encode(checkout))
  end

  it "exposes the resolved rental route to the SPA without a redirect" do
    rental = "/rentals/spots/#{BSON::ObjectId.new}"
    code = ShortUrl.allocate(rental)[:code]
    get "/L#{code}"
    expect(response.status).to eq(200)
    expect(response.headers["Location"]).to be_nil
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('meta[name="shortcode-target"]')["content"]).to eq(rental)
    expect(html.css("script").first["id"]).to eq("shortcode-routing")
    expect(html.css("script").first.text).to include("history.replaceState")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end
end
