require "rails_helper"

RSpec.describe "Mailtrap webhooks", type: :request do
  let(:member) { create(:member, email: "mailtrap-member@example.com") }
  let(:event_timestamp) { Time.utc(2026, 4, 24, 12, 0, 0).to_i }
  let(:payload_hash) do
    {
      events: [
        {
          event: "delivery",
          event_id: "evt_123",
          message_id: "msg_123",
          email: member.email,
          sending_stream: "transactional",
          sending_domain_name: "example.com",
          timestamp: event_timestamp,
          response: "250 2.0.0 Ok"
        }
      ]
    }
  end
  let(:payload) { JSON.generate(payload_hash) }

  def post_webhook(body:, headers: {})
    post "/mailtrap_listener", params: body, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  it "stores matching mailtrap events and updates the member record" do
    create(:member)

    expect do
      post_webhook(body: payload)
    end.to change(MailtrapEvent, :count).by(1)

    expect(response).to have_http_status(200)

    mailtrap_event = MailtrapEvent.last
    member.reload

    expect(mailtrap_event.email).to eq(member.email)
    expect(mailtrap_event.status).to eq("delivery")
    expect(mailtrap_event.member_id).to eq(member.id)
    expect(mailtrap_event.message_id).to eq("msg_123")
    expect(mailtrap_event.response).to eq("250 2.0.0 Ok")
    expect(mailtrap_event.occurred_at.to_i).to eq(event_timestamp)
    expect(member.mailtrap_id).to eq(mailtrap_event.id)
  end

  it "verifies the Mailtrap signature when a secret is configured" do
    original_secret = ENV["MAILTRAP_WEBHOOK_SIGNATURE"]
    ENV["MAILTRAP_WEBHOOK_SIGNATURE"] = "mailtrap-secret"
    begin
      signature = OpenSSL::HMAC.hexdigest("SHA256", "mailtrap-secret", payload)

      expect do
        post_webhook(body: payload, headers: { "HTTP_MAILTRAP_SIGNATURE" => signature })
      end.to change(MailtrapEvent, :count).by(1)

      expect(response).to have_http_status(200)
    ensure
      ENV["MAILTRAP_WEBHOOK_SIGNATURE"] = original_secret
    end
  end

  it "logs an error and rejects the webhook when the signature is invalid" do
    expect(Rails.logger).to receive(:error).with("[Mailtrap] Webhook signature validation failed")

    original_secret = ENV["MAILTRAP_WEBHOOK_SIGNATURE"]
    ENV["MAILTRAP_WEBHOOK_SIGNATURE"] = "mailtrap-secret"
    begin
      expect do
        post_webhook(body: payload, headers: { "HTTP_MAILTRAP_SIGNATURE" => "bad-signature" })
      end.not_to change(MailtrapEvent, :count)

      expect(response).to have_http_status(401)
    ensure
      ENV["MAILTRAP_WEBHOOK_SIGNATURE"] = original_secret
    end
  end

  it "does not create a mailtrap record when no member matches the recipient email" do
    payload_hash[:events][0][:email] = "missing-member@example.com"

    expect do
      post_webhook(body: JSON.generate(payload_hash))
    end.not_to change(MailtrapEvent, :count)

    expect(response).to have_http_status(200)
  end
end
