require "rails_helper"

RSpec.describe "Public shortcode resolution", type: :request do
  let!(:shop) { create(:shop) }
  let!(:tool) { create(:tool, shop: shop) }
  let(:target) { "/tools/#{tool.id}/request-checkout" }
  let(:code) { "23456789AB" }

  before do
    allow(ShortUrl).to receive(:base_url).and_return("https://members.example.org")
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set)
    Shortcode.create!(code: code, target_url: target)
  end

  it "resolves without login but does not grant checkout access" do
    get "/api/shortcodes/#{code}"
    expect(response.parsed_body).to eq("target_path" => target)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Set-Cookie"]).to be_nil
    get target
    expect(response).to redirect_to("/login?return_to=#{ERB::Util.url_encode(target)}")
  end

  it "rechecks the visibility of a cached destination" do
    allow(REDIS).to receive(:get).and_return(target)
    tool.update!(disabled: true)
    get "/api/shortcodes/#{code}"
    expect(response.status).to eq(404)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "rejects invalid and unknown codes without caching their errors" do
    ["bad", "ZZZZZZZZZZ", code.downcase].each do |invalid|
      get "/api/shortcodes/#{invalid}"
      expect(response.status).to eq(404)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "fails closed for an invalid stored target" do
    allow(ShortUrl).to receive(:resolve).and_return("https://members.example.org/admin")
    get "/api/shortcodes/#{code}"
    expect(response.status).to eq(404)
  end

  it "returns an uncached service error when storage is unavailable" do
    allow(ShortUrl).to receive(:resolve).and_raise(ShortUrl::Unavailable)
    get "/api/shortcodes/#{code}"
    expect(response.status).to eq(503)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end
end
