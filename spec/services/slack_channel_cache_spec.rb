require "rails_helper"

RSpec.describe Service::SlackChannelCache do
  let(:client) { instance_double(Slack::Web::Client) }
  let(:first_page) do
    double(
      channels: [
        double(
          id: "C12345678",
          name: "wood-shop",
          topic: double(value: "Woodworking discussion"),
          purpose: double(value: "Coordinate the wood shop")
        )
      ],
      response_metadata: double(next_cursor: "next")
    )
  end
  let(:second_page) do
    double(
      channels: [
        double(
          id: "C45678901",
          name: "metal-shop",
          topic: double(value: "Metalworking discussion"),
          purpose: double(value: "Coordinate the metal shop")
        )
      ],
      response_metadata: double(next_cursor: "")
    )
  end

  before do
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:del).and_return(1)
    allow(REDIS).to receive(:rename).and_return(true)
    allow(REDIS).to receive(:eval).and_return(true)
    allow(REDIS).to receive(:multi) do |&block|
      block.call(REDIS)
      []
    end
    allow(REDIS).to receive(:scan_each).and_return([].each)
  end

  it "distinguishes hash-prefixed channel names from Slack channel IDs" do
    expect(described_class.normalize_name("#COMMUNITY")).to eq("#community")
    expect(described_class.normalize_name("C12345678")).to eq("C12345678")
    expect(described_class.channel_id?("community")).to be(false)
    expect(described_class.channel_id?("C12345678")).to be(true)
  end

  it "stores a resolved channel under both its name and id" do
    described_class.store(id: "G12345678", name: "#Officers-Private")

    expect(REDIS).to have_received(:set).with(
      "slack:public_channel:#officers-private",
      JSON.generate(id: "G12345678", name: "#officers-private"),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel_id:G12345678",
      JSON.generate(id: "G12345678", name: "#officers-private"),
      ex: described_class::CACHE_TTL_SECONDS
    )
  end

  it "does not store a channel with a blank id or name" do
    described_class.store(id: "", name: "officers-private")
    described_class.store(id: "G12345678", name: "")

    expect(REDIS).not_to have_received(:set)
  end

  it "normalizes names and caches every channel encountered until the target is found" do
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)

    result = described_class.lookup("#METAL-SHOP", refresh_on_miss: true)

    expect(result).to include(
      "id" => "C45678901",
      "name" => "#metal-shop",
      "topic" => "Metalworking discussion",
      "purpose" => "Coordinate the metal shop"
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel:#wood-shop",
      include('"id":"C12345678"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel:#metal-shop",
      include('"id":"C45678901"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel_id:C12345678",
      include('"name":"#wood-shop"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel_id:C45678901",
      include('"name":"#metal-shop"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
  end

  it "resolves channel IDs during a paginated refresh" do
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)

    result = described_class.lookup("C45678901", refresh_on_miss: true)

    expect(result).to include(
      "id" => "C45678901",
      "name" => "#metal-shop",
      "topic" => "Metalworking discussion"
    )
    expect(client).to have_received(:conversations_list).twice
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel_id:C45678901",
      include('"name":"#metal-shop"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
  end

  it "returns cached channel details without calling Slack" do
    allow(REDIS).to receive(:get).with("slack:public_channel:#wood-shop")
      .and_return(JSON.generate(
        id: "C12345678", name: "#wood-shop", topic: "Topic", purpose: "Purpose"
      ))

    expect(described_class.lookup("#wood-shop")).to include("id" => "C12345678")
    expect(client).not_to receive(:conversations_list)
  end

  it "returns channel details cached by ID without calling Slack" do
    allow(REDIS).to receive(:get)
      .with("slack:public_channel_id:C12345678")
      .and_return(JSON.generate(
        id: "C12345678", name: "#wood-shop", topic: "Topic", purpose: "Purpose"
      ))

    expect(described_class.lookup("C12345678")).to include(
      "name" => "#wood-shop"
    )
    expect(client).not_to receive(:conversations_list)
  end

  it "reports the current key count and last full update" do
    allow(REDIS).to receive(:get).with(described_class::STATUS_KEY)
      .and_return(JSON.generate(lastUpdatedAt: "2026-07-28T12:00:00Z"))
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[channel-one channel-two].each)

    expect(described_class.status).to eq(
      available: true,
      total_channels: 2,
      last_updated_at: "2026-07-28T12:00:00Z"
    )
  end

  it "finishes scanning before replacing stale keys and records cache metadata" do
    events = []
    promotion = nil
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[slack:public_channel:old].each)
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel_id:*")
      .and_return(%w[slack:public_channel_id:COLD12345].each)
    allow(client).to receive(:conversations_list) do
      events << :scan
      events.count(:scan) == 1 ? first_page : second_page
    end
    allow(REDIS).to receive(:eval) do |script, keys:, argv:|
      events << :promote
      promotion = { script: script, keys: keys, argv: argv }
      true
    end

    expect(described_class.rebuild!).to eq(2)

    expect(events.index(:promote)).to be > events.rindex(:scan)
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:\#wood-shop/
      ),
      include('"id":"C12345678"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:\#metal-shop/
      ),
      include('"id":"C45678901"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:C12345678/
      ),
      include('"name":"#wood-shop"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:C45678901/
      ),
      include('"name":"#metal-shop"'),
      ex: described_class::CACHE_TTL_SECONDS
    )
    expect(promotion[:keys]).to include(
      "slack:public_channel:old",
      "slack:public_channel_id:COLD12345",
      described_class::STATUS_KEY
    )
    expect(promotion[:argv].first(2)).to eq([4, 2])
    expect(promotion[:argv]).to include(
      "slack:public_channel:#wood-shop",
      "slack:public_channel:#metal-shop",
      "slack:public_channel_id:C12345678",
      "slack:public_channel_id:C45678901",
      a_string_including('"totalChannels":2', '"lastUpdatedAt"'),
      described_class::CACHE_TTL_SECONDS
    )
    expect(promotion[:script].index('redis.call("EXISTS"'))
      .to be < promotion[:script].index('redis.call("DEL"')
  end

  it "preserves live keys when a staging key disappears before promotion" do
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[slack:public_channel:old].each)
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)
    allow(REDIS).to receive(:eval)
      .and_raise(
        Redis::CommandError,
        "Slack cache staging key missing: rebuild-key"
      )

    expect { described_class.rebuild! }
      .to raise_error(Redis::CommandError, /staging key missing/)

    expect(REDIS).not_to have_received(:del)
      .with("slack:public_channel:old")
    expect(REDIS).not_to have_received(:rename)
  end

  it "preserves the existing cache when Slack pagination fails" do
    requests = 0
    allow(client).to receive(:conversations_list) do
      requests += 1
      raise StandardError, "temporary Slack failure" if requests == 2

      first_page
    end

    expect { described_class.rebuild! }
      .to raise_error(RuntimeError, "Slack public-channel cache rebuild failed")

    expect(REDIS).not_to have_received(:scan_each)
    expect(REDIS).not_to have_received(:del)
    expect(REDIS).not_to have_received(:set)
  end

  it "fails without promoting or clearing when a staged Redis write fails" do
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[slack:public_channel:old].each)
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)
    allow(REDIS).to receive(:set) do |key, _value, **_options|
      if key.end_with?("#metal-shop")
        raise Redis::CommandError, "temporary Redis failure"
      end

      true
    end

    expect { described_class.rebuild! }
      .to raise_error(Redis::CommandError, "temporary Redis failure")

    expect(REDIS).not_to have_received(:multi)
    expect(REDIS).not_to have_received(:scan_each)
    expect(REDIS).not_to have_received(:del)
      .with("slack:public_channel:old")
    expect(REDIS).not_to have_received(:rename)
  end
end
