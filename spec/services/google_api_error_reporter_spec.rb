require "rails_helper"

RSpec.describe Service::GoogleApiErrorReporter do
  FakePermissionError = Class.new(StandardError) do
    attr_reader :status_code, :body, :response_header

    def initialize
      super("PERMISSION_DENIED: caller lacks calendar ownership")
      @status_code = 403
      @body = '{"error":{"status":"PERMISSION_DENIED","message":"Owner access required"}}'
      @response_header = { "x-request-id" => "google-request-123" }
    end
  end

  it "persists and alerts with the complete Google permission error" do
    error = FakePermissionError.new
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.report_if_permission_denied(
      error,
      operation: "calendar.labels.ensure",
      resource_type: "Shop",
      resource_id: BSON::ObjectId.new
    )

    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        event_type: "google_api_permission_denied",
        after_snapshot: hash_including(
          error_message: include(
            "caller lacks calendar ownership",
            "Owner access required",
            "google-request-123"
          )
        )
      )
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      include("caller lacks calendar ownership", "Owner access required", "google-request-123"),
      anything
    )
  end

  it "redacts authorization headers embedded in Faraday response text" do
    error = StandardError.new(
      'request=#<Faraday::Response request_headers={' \
      '"Authorization"=>"Bearer request-secret"} ' \
      'response_headers={"authorization"=>"Bearer response-secret"}>'
    )

    message = described_class.full_error_message(error)

    expect(message).to include(
      '"Authorization"=>"[FILTERED]"',
      '"authorization"=>"[FILTERED]"'
    )
    expect(message).not_to include("request-secret", "response-secret")
    expect(error.message).not_to include("request-secret", "response-secret")
    expect(error.inspect).not_to include("request-secret", "response-secret")
  end

  it "redacts authorization values in returned response-header hashes" do
    error_class = Class.new(StandardError) do
      attr_reader :response_header

      def initialize
        super("Google API failure")
        @response_header = {
          "Authorization" => "Bearer response-secret",
          "x-request-id" => "google-request-123"
        }
      end
    end

    message = described_class.full_error_message(error_class.new)

    expect(message).to include("[FILTERED]", "google-request-123")
    expect(message).not_to include("response-secret")
  end

  it "keeps repeated sanitization idempotent" do
    error = StandardError.new("Authorization: Bearer response-secret")

    3.times { described_class.sanitize_error!(error) }

    expect(error.message).to eq("Authorization: [FILTERED]")
  end
end
