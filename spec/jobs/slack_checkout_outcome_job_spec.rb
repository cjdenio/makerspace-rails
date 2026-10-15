require "rails_helper"

if ENV['RUN_OPTIONAL_SLACK_CHECKOUT_SPECS'] == 'true'
  RSpec.describe SlackCheckoutOutcomeJob do
    let(:url) { "https://hooks.slack.test/commands/PRIVATE-CREDENTIAL" }
    let(:token) { described_class.encryptor.encrypt_and_sign(url) }
    let(:http) { instance_double(Net::HTTP) }
    before do
      allow(Service::ErrorReporter).to receive(:notify)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    it "replaces the ephemeral response with bounded timeouts and no DM" do
      expect(Net::HTTP).to receive(:start).with("hooks.slack.test", 443, use_ssl: true,
        open_timeout: 0.5, read_timeout: 1, write_timeout: 0.5).and_yield(http)
      expect(http).to receive(:request) do |request|
        expect(JSON.parse(request.body)).to eq("replace_original" => true, "response_type" => "ephemeral", "text" => "Saved")
        Net::HTTPOK.new("1.1", "200", "OK")
      end
      described_class.perform_now("Saved", token, "UACTOR")
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it "reports non-2xx replacement separately and falls back to the submitting user's DM" do
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_return(Net::HTTPBadGateway.new("1.1", "502", "Bad Gateway"))
      described_class.perform_now("Saved", token, "UACTOR")
      expect(Service::ErrorReporter).to have_received(:notify).with("Slack checkout outcome replacement failed", context: { phase: "replacement", http_status: "502" })
      expect(Service::SlackConnector).to have_received(:send_slack_message).with("Saved", "UACTOR")
    end

    it "never reports raw exception messages, even when both delivery paths contain the credential" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout, url)
      allow(Service::SlackConnector).to receive(:send_slack_message).and_raise(StandardError, url)
      reports = []
      allow(Service::ErrorReporter).to receive(:notify) { |message, **context| reports << [message, context] }
      expect { described_class.perform_now("Saved", token, "UACTOR") }.not_to raise_error
      expect(reports.to_json).not_to include(url, "PRIVATE-CREDENTIAL")
      expect(reports.map { |_, value| value.dig(:context, :phase) }).to eq(%w[replacement DM])
    end

    it "encrypts job arguments before enqueueing and suppresses argument logging" do
      described_class.enqueue("Saved", url, "UACTOR")
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.reverse.find { |entry| entry[:job] == described_class }
      expect(job[:args].to_json).not_to include(url, "PRIVATE-CREDENTIAL")
      expect(described_class.encryptor.decrypt_and_verify(job[:args][1])).to eq(url)
      expect(described_class.log_arguments).to be(false)
    end

    it "sanitizes enqueue exceptions and returns false without delivery in the caller" do
      allow(described_class).to receive(:perform_later).and_raise(StandardError, url)
      expect(Net::HTTP).not_to receive(:start)
      expect(described_class.enqueue("Saved", url, "UACTOR")).to be(false)
      expect(Service::ErrorReporter).to have_received(:notify).with("Slack checkout outcome enqueue failed",
        context: { phase: "enqueue", error_class: "StandardError" })
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it "survives a failed reporter and an invalid response URL" do
      allow(Service::ErrorReporter).to receive(:notify).and_raise(StandardError, url)
      expect { described_class.perform_now("Saved", described_class.encryptor.encrypt_and_sign("bad-url"), "UACTOR") }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with("Saved", "UACTOR")
    end
  end
end
