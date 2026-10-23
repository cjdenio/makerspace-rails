require "rails_helper"

# Regression coverage for the "No subject recorded" bug: Mailtrap's own
# message_id (its internal tracking id) never matches the SMTP Message-ID
# this app generated at send time, so the two records could never link.
# These specs are not gated behind RUN_OPTIONAL_MAILTRAP_SPECS -- the
# existing webhook specs in spec/optional are, which meant this join was
# never actually exercised in CI.
RSpec.describe "Mailtrap webhooks", type: :request do
  let(:member) { create(:member, email: "mailtrap-member@example.com") }

  def post_webhook(body:)
    post "/mailtrap_listener", params: body, headers: { "CONTENT_TYPE" => "application/json" }
  end

  it "links a webhook event back to the MailtrapMessage via the app_message_id custom variable" do
    mailtrap_message = MailtrapMessage.create!(
      message_id:   "our-own-uuid@manchestermakerspace.org",
      subject:      "Your receipt",
      email:        member.email,
      mailer_class: "BillingMailer",
      action:       "receipt",
      member_id:    member.id
    )
    payload = {
      events: [
        {
          event:            "delivery",
          event_id:         "evt_123",
          message_id:       "msg_123", # Mailtrap's own tracking id -- deliberately different
          custom_variables: { app_message_id: "our-own-uuid@manchestermakerspace.org" },
          email:            member.email,
          sending_stream:   "transactional",
          timestamp:        Time.current.to_i
        }
      ]
    }

    post_webhook(body: JSON.generate(payload))

    expect(response).to have_http_status(200)
    mailtrap_event = MailtrapEvent.last
    expect(mailtrap_event.mailtrap_message_id).to eq(mailtrap_message.id)
  end

  it "does not link when no matching app_message_id custom variable is present" do
    payload = {
      events: [
        {
          event:          "delivery",
          event_id:       "evt_124",
          message_id:     "msg_124",
          email:          member.email,
          sending_stream: "transactional",
          timestamp:      Time.current.to_i
        }
      ]
    }

    post_webhook(body: JSON.generate(payload))

    expect(response).to have_http_status(200)
    expect(MailtrapEvent.last.mailtrap_message_id).to be_nil
  end
end
