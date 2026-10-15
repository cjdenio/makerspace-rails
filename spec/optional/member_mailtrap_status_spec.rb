require 'rails_helper'

if ENV['RUN_OPTIONAL_MAILTRAP_SPECS'] == 'true'
  RSpec.describe MembersController, type: :controller do
    describe 'GET #show' do
      login_user

      it "includes the latest mailtrap details when mailtrap_id is present" do
        mailtrap_event = create(:mailtrap_event, member: current_user, email: current_user.email, occurred_at: Time.utc(2026, 4, 24, 12, 30, 0))
        current_user.set(mailtrap_id: mailtrap_event.id)

        get :show, params: { id: current_user.to_param }, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(parsed_response["mailtrap"]).to include(
          "email" => current_user.email,
          "status" => "delivery",
          "timestamp" => "2026-04-24T08:30:00-04:00"
        )
      end

      it "does not show a successful mailtrap status from a stale email address" do
        old_email_event = create(:mailtrap_event, member: current_user, email: "old-#{current_user.email}", occurred_at: Time.utc(2026, 4, 24, 12, 30, 0))
        current_user.set(mailtrap_id: old_email_event.id)

        get :show, params: { id: current_user.to_param }, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(parsed_response["mailtrap"]).to include(
          "email" => current_user.email,
          "status" => "unknown",
          "value" => "No attempts made"
        )
      end

      it "uses the latest mailtrap record matching the member's current email" do
        old_email_event = create(:mailtrap_event, member: current_user, email: "old-#{current_user.email}", occurred_at: Time.utc(2026, 4, 24, 12, 30, 0))
        create(:mailtrap_event, member: current_user, email: current_user.email, status: "bounce", event: "bounce", occurred_at: Time.utc(2026, 5, 1, 12, 30, 0))
        current_user.set(mailtrap_id: old_email_event.id)

        get :show, params: { id: current_user.to_param }, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(parsed_response["mailtrap"]).to include(
          "email" => current_user.email,
          "status" => "bounce",
          "timestamp" => "2026-05-01T08:30:00-04:00"
        )
      end
    end
  end

  RSpec.describe MemberSummarySerializer do
    it "uses preloaded mailtrap events without fallback queries" do
      member = create(:member, email: "current@example.com")
      old_event = create(:mailtrap_event, member: member, email: "old@example.com")
      current_event = create(:mailtrap_event, member: member, email: member.email, status: "delivery")
      member.set(mailtrap_id: old_event.id)

      expect(MailtrapEvent).not_to receive(:where)

      payload = ActiveModelSerializers::SerializableResource.new(
        member.reload,
        serializer: MemberSummarySerializer,
        adapter: :attributes,
        mailtrap_events_by_member_id_email: { [member.id.to_s, member.email] => current_event }
      ).as_json

      expect(payload[:mailtrap]).to include(
        email: member.email,
        status: "delivery",
        value: "delivery"
      )
    end
  end

end
