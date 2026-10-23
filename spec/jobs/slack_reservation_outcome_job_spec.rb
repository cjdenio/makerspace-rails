require "rails_helper"

RSpec.describe SlackReservationOutcomeJob do
  let(:message) { "Reservation *Lathe time* was created and is *approved*." }
  let(:response_url) { "https://hooks.slack.test/responses/secret" }
  let(:slack_user_id) { "U123" }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Service::ErrorReporter).to receive(:notify)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def http_response(klass, code)
    klass.new("1.1", code, nil)
  end

  it "replaces the original response with strict network timeouts" do
    expect(Net::HTTP).to receive(:start).with(
      "hooks.slack.test",
      443,
      use_ssl: true,
      open_timeout: 1,
      read_timeout: 2,
      write_timeout: 1
    ).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request).to be_a(Net::HTTP::Post)
      expect(request["Content-Type"]).to eq("application/json")
      expect(JSON.parse(request.body)).to include(
        "response_type" => "ephemeral",
        "replace_original" => true,
        "text" => message
      )
      http_response(Net::HTTPOK, "200")
    end

    described_class.perform_now(message, response_url, slack_user_id)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "reports an unsuccessful replacement and falls back to a DM" do
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(http_response(Net::HTTPBadGateway, "502"))

    described_class.perform_now(message, response_url, slack_user_id)

    expect(Service::ErrorReporter).to have_received(:notify).with(
      anything,
      context: hash_including(phase: "Slack reservation response replacement", http_status: "502")
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(message, slack_user_id)
  end

  it "falls back to a DM when replacement times out" do
    allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout, "timed out")

    described_class.perform_now(message, response_url, slack_user_id)

    expect(Service::ErrorReporter).to have_received(:notify).with(
      instance_of(Net::ReadTimeout),
      context: hash_including(phase: "Slack reservation response replacement")
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(message, slack_user_id)
  end

  it "reports total notification failure without exposing the response URL" do
    allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout, "timed out")
    allow(Service::SlackConnector).to receive(:send_slack_message).and_raise(StandardError, "DM failed")

    expect do
      described_class.perform_now(message, response_url, slack_user_id)
    end.not_to raise_error

    expect(Service::ErrorReporter).to have_received(:notify).with(
      instance_of(StandardError),
      context: {
        phase: "Slack reservation outcome delivery",
        slack_user_id: slack_user_id
      }
    )
    expect(Service::ErrorReporter).not_to have_received(:notify).with(
      anything,
      context: hash_including(response_url: anything)
    )
  end
end
