require "rails_helper"

RSpec.describe Service::SlackConnector do
  let(:client) { double("Slack client") }

  before do
    allow(described_class).to receive(:client).and_return(client)
  end

  it "creates an unbound canvas and grants a shop channel read access" do
    allow(client).to receive(:canvases_create)
      .with(title: "Today's Reservations")
      .and_return(double(canvas_id: "F123"))
    expect(client).to receive(:canvases_access_set).with(
      canvas_id: "F123",
      access_level: "read",
      channel_ids: '["C123"]'
    )

    canvas_id = described_class.create_canvas("Today's Reservations")
    described_class.set_canvas_channel_access(canvas_id, "C123")

    expect(canvas_id).to eq("F123")
  end

  it "grants a list of Slack users the requested canvas access" do
    expect(client).to receive(:canvases_access_set).with(
      canvas_id: "F123",
      access_level: "owner",
      user_ids: '["UADMIN","UBOARD","URM"]'
    )

    described_class.set_canvas_user_access(
      "F123",
      %w[UADMIN UBOARD URM],
      access_level: "owner"
    )
  end

  it "waits for Slack's Retry-After duration and retries a rate-limited API call" do
    response = double(headers: { "retry-after" => "7" })
    error = Slack::Web::Api::Errors::TooManyRequestsError.new(response)
    attempts = 0
    allow(client).to receive(:canvases_create) do
      attempts += 1
      raise error if attempts == 1

      double(canvas_id: "F123")
    end
    allow(described_class).to receive(:sleep)

    expect(described_class.create_canvas("Reservations")).to eq("F123")
    expect(described_class).to have_received(:sleep).with(7)
    expect(client).to have_received(:canvases_create).twice
  end

  it "replaces the entire canvas with the rendered agenda" do
    expect(client).to receive(:canvases_edit) do |arguments|
      expect(arguments[:canvas_id]).to eq("F123")
      expect(JSON.parse(arguments[:changes], symbolize_names: true)).to eq(
        [
          {
            operation: "replace",
            document_content: {
              type: "markdown",
              markdown: "# Woodshop Reservations"
            }
          }
        ]
      )
    end

    described_class.replace_canvas("F123", "# Woodshop Reservations")
  end

  it "includes Slack's HTTP status and response body in API errors" do
    response = double(
      status: 400,
      body: {
        ok: false,
        error: "missing_argument",
        response_metadata: {
          messages: ["[ERROR] missing required field: channel_ids"]
        }
      }
    )
    error = Slack::Web::Api::Errors::MissingArgument.new(
      "missing_argument",
      response
    )

    expect(described_class.format_api_error(error)).to include(
      "MissingArgument: missing_argument",
      "http_status=400",
      '"error":"missing_argument"',
      "missing required field: channel_ids"
    )
  end

  it "resolves a configured channel name to its Slack channel ID" do
    channel = double(name: "woodshop", id: "C123")
    response = double(
      channels: [channel],
      response_metadata: double(next_cursor: "")
    )
    expect(client).to receive(:conversations_list).with(
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
      cursor: nil
    ).and_return(response)

    expect(described_class.find_channel_id("#woodshop")).to eq("C123")
  end

  it "resolves an ID-shaped hash-prefixed channel as a name" do
    channel = double(name: "community", id: "C12345678")
    response = double(
      channels: [channel],
      response_metadata: double(next_cursor: "")
    )
    allow(Service::SlackChannelCache).to receive(:fetch).and_return(nil)
    expect(client).not_to receive(:conversations_info)
    expect(client).to receive(:conversations_list).with(
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
      cursor: nil
    ).and_return(response)

    expect(described_class.find_channel_id("#COMMUNITY")).to eq("C12345678")
  end

  it "resolves an uppercase Slack channel ID with conversations.info" do
    channel = double(id: "C12345678", is_archived: false)
    allow(Service::SlackChannelCache).to receive(:fetch).and_return(nil)
    expect(client).to receive(:conversations_info)
      .with(channel: "C12345678")
      .and_return(double(channel: channel))
    expect(client).not_to receive(:conversations_list)

    expect(described_class.find_channel_id("C12345678")).to eq("C12345678")
  end
end
