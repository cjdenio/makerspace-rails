require "rails_helper"

RSpec.describe AppDomainUrl do
  describe ".host" do
    it "returns only the normalized host" do
      expect(described_class.host("https://members.example.org/"))
        .to eq("members.example.org")
      expect(described_class.host("http://https://localhost:3035"))
        .to eq("localhost:3035")
    end

    it "produces a valid URL when passed to Rails with a separate protocol" do
      url = Rails.application.routes.url_helpers.root_url(
        host: described_class.host("https://members.example.org"),
        protocol: "https"
      )

      expect(url).to eq("https://members.example.org/")
    end
  end

  describe ".base_url" do
    it "uses HTTP for local and non-secure test domains" do
      expect(described_class.base_url("localhost:3035", environment: "test"))
        .to eq("http://localhost:3035")
      expect(described_class.base_url("portal.example.test", environment: "test"))
        .to eq("http://portal.example.test")
    end

    it "forces HTTPS for com, net, and org hostnames" do
      expect(described_class.base_url("http://members.example.com", environment: "test"))
        .to eq("https://members.example.com")
      expect(described_class.base_url("members.example.net:3035", environment: "test"))
        .to eq("https://members.example.net:3035")
      expect(described_class.base_url("https://members.example.org", environment: "test"))
        .to eq("https://members.example.org")
    end

    it "forces HTTPS in production regardless of the hostname" do
      expect(described_class.base_url("http://internal.local", environment: "production"))
        .to eq("https://internal.local")
    end

    it "honors ENVIRONMENT=production" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ENVIRONMENT").and_return("production")

      expect(described_class.base_url("internal.local", environment: "test"))
        .to eq("https://internal.local")
    end

    it "removes repeated protocols before applying the protocol rule" do
      expect(described_class.base_url("http://https://localhost:3035", environment: "test"))
        .to eq("http://localhost:3035")
    end
  end
end
