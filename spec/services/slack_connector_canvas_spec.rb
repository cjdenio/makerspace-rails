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

  it "renames an existing canvas using an encoded title operation" do
    expect(client).to receive(:canvases_edit) do |arguments|
      expect(arguments[:canvas_id]).to eq('F123')
      expect(JSON.parse(arguments[:changes])).to eq([
        { 'operation' => 'rename', 'title_content' => { 'type' => 'markdown', 'markdown' => 'Volunteer opportunities' } }
      ])
    end
    described_class.rename_canvas('F123', 'Volunteer opportunities')
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

  it "looks up canvas sections containing text" do
    expect(client).to receive(:canvases_sections_lookup).with(
      canvas_id: "F123",
      criteria: JSON.generate(contains_text: "Table Saw", section_types: ["h3"])
    ).and_return(double(sections: [double(id: "S123")]))

    sections = described_class.lookup_canvas_sections(
      "F123",
      contains_text: "Table Saw",
      section_types: ["h3"]
    )

    expect(sections.first.id).to eq("S123")
  end

  it "applies targeted canvas changes" do
    changes = [{ operation: "delete", section_id: "S123" }]
    expect(client).to receive(:canvases_edit).with(
      canvas_id: "F123",
      changes: JSON.generate(changes)
    )

    described_class.edit_canvas("F123", changes)
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

  it "logs the complete Slack validation messages and filters secrets from requests and responses" do
    validation_message = "invalid block " + ("detail " * 1_000)
    response = double(
      status: 400,
      body: {
        ok: false,
        response_metadata: { messages: [validation_message, "received xoxb-embedded-secret"] },
        token: "response-secret"
      }
    )
    error = Slack::Web::Api::Errors::InvalidArguments.new("invalid_arguments", response)

    details = described_class.format_api_error(
      error,
      request: {
        method: "views.open",
        arguments: {
          trigger_id: "trigger-secret",
          view: { private_metadata: "private-ticket-context", callback_id: "not-a-secret" },
          api_key: "request-secret"
        }
      }
    )

    expect(details).to include(validation_message, "not-a-secret")
    expect(details).to include('"trigger_id":"[FILTERED]"', '"api_key":"[FILTERED]"', '"token":"[FILTERED]"', '"private_metadata":"[FILTERED]"')
    expect(details).not_to include("trigger-secret", "request-secret", "response-secret", "xoxb-embedded-secret", "private-ticket-context")
  end

  it "logs filtered extended details before reraising a missing-scope error" do
    response = double(
      status: 200,
      body: {
        ok: false,
        error: "missing_scope",
        needed: "chat:write",
        provided: "channels:read",
        response_metadata: { messages: ["missing chat:write for xoxb-embedded-secret"] },
        token: "response-secret"
      }
    )
    error = Slack::Web::Api::Errors::MissingScope.new("missing_scope", response)
    allow(Rails.env).to receive(:test?).and_return(false)
    allow(client).to receive(:chat_postMessage).and_raise(error)

    expect {
      expect {
        described_class.send_slack_message("hello", "C123")
      }.to raise_error(error)
    }.to output(
      a_string_including(
        "[SlackMissingScope]",
        '"needed":"chat:write"',
        '"provided":"channels:read"',
        "missing chat:write for [FILTERED]",
        '"token":"[FILTERED]"'
      )
    ).to_stderr
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

  it "reports a missing channel and the filtered Slack response to interface logs and Honeybadger" do
    response = {
      status: 404,
      body: { ok: false, error: "channel_not_found", token: "response-secret" },
      headers: { "x-slack-req-id" => "request-123" }
    }
    error = Slack::Web::Api::Errors::ChannelNotFound.new("channel_not_found", response)
    allow(Service::SlackChannelCache).to receive(:fetch).and_return(nil)
    allow(client).to receive(:conversations_info).and_raise(error)
    allow(described_class).to receive(:send_slack_message)
    allow(Honeybadger).to receive(:notify)

    expect(described_class.find_channel_id("C12345678")).to be_nil
    expect(described_class).to have_received(:send_slack_message).with(
      a_string_including(
        "[SlackChannelNotFound]",
        'channel="C12345678"',
        '"error":"channel_not_found"',
        '"token":"[FILTERED]"',
        '"x-slack-req-id":"request-123"'
      ),
      described_class.logs_channel
    )
    expect(Honeybadger).to have_received(:notify).with(
      error,
      context: {
        operation: "conversations.info",
        channel: "C12345678",
        slack_response: {
          status: 404,
          body: { ok: false, error: "channel_not_found", token: "[FILTERED]" },
          headers: { "x-slack-req-id" => "request-123" }
        }
      }
    )
  end

  it "defers channel_not_found diagnostics to a caller that has a fallback" do
    response = { ok: false, error: "channel_not_found" }
    error = Slack::Web::Api::Errors::ChannelNotFound.new("channel_not_found", response)
    captured_error = nil
    allow(Service::SlackChannelCache).to receive(:fetch).and_return(nil)
    allow(client).to receive(:conversations_info).and_raise(error)
    allow(described_class).to receive(:report_channel_not_found)

    result = described_class.find_channel_id(
      "C12345678",
      on_channel_not_found: ->(caught_error) { captured_error = caught_error }
    )

    expect(result).to be_nil
    expect(captured_error).to be(error)
    expect(described_class).not_to have_received(:report_channel_not_found)
  end
end
