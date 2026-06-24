require 'rails_helper'

RSpec.describe Admin::MembersController, type: :controller do

  let(:valid_attributes) {
    {
      firstname: 'Test',
      lastname: 'Tester',
      email: 'test@test.com',
    }
  }

  def get_fullname(member)
    return member[:firstname] + " " + member[:lastname]
  end

  # Need this because we store things in milliseconds instead of ruby seconds
  def conv_to_ms(time)
    time.to_i * 1000
  end

  describe "Authenticated admin" do
    login_admin

    describe "POST #create" do
      context "with valid params" do
        it "creates a new member" do
          expect {
            post :create, params: valid_attributes, format: :json
          }.to change(Member, :count).by(1)
        end

        it "assigns a newly created member as @member" do
          post :create, params: valid_attributes, format: :json
          one_month_later_after = Time.now + 1.month;

          expect(Member.last).to be_a(Member)
          expect(Member.last).to be_persisted
          expect(Member.last.firstname).to eq(valid_attributes[:firstname])
        end

        it "renders json of the created member" do
          post :create, params: valid_attributes, format: :json

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(200)
          expect(response.media_type).to eq "application/json"
          expect(parsed_response['id']).to eq(Member.last.id.as_json)
        end

        it "sends an email for the created member to reset password" do
          expect(MemberMailer).to receive(:welcome_email_manual_register).and_call_original
          post :create, params: valid_attributes, format: :json
        end
      end

      context "with invalid params" do
        missing_member_prop = {
          firstname: 'Test',
          email: 'test@test.com',
        }

        before(:each) do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return("true")
        end

        it "raises validation error with invalid params" do
          post :create, params: missing_member_prop, format: :json

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(422)
          expect(parsed_response['message']).to match(/lastname/i)
        end
      end
    end

    describe "PUT #update" do
      context "with valid params" do
        let(:new_attributes) {
          {
            email: 'new_email@test.com',
            firstname: 'Change',
            lastname: 'Name',
            renew: 1
          }
        }
        create_attr = {
            email: 'new_email@test.com',
            firstname: 'Change',
            lastname: 'Name',
        }

        it "updates the requested member" do
          member = Member.create create_attr
          one_month_later = Time.now + 1.month;
          put :update, params: new_attributes.merge({ id: member.to_param }), format: :json
          one_month_later_after = Time.now + 1.month;

          member.reload
          expect(member.email).to eq(new_attributes[:email])
          expect(member.fullname).to eq(get_fullname(new_attributes))
          expect(member.expirationTime).to be >= conv_to_ms(one_month_later)
          expect(member.expirationTime).to be <= conv_to_ms(one_month_later_after)
        end

        it "renders json of the member" do
          member = Member.create valid_attributes
          put :update, params: new_attributes.merge({ id: member.to_param }), format: :json

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(200)
          expect(response.media_type).to eq "application/json"
          expect(parsed_response['id']).to eq(member.id.as_json)
        end

        it "Sends a slack notification" do
          member = Member.create valid_attributes.merge({ expirationTime: ((Time.now + 1.month).strftime('%s').to_i * 1000)})
          initial_expiration = member.pretty_time
          expect(Member).to receive(:find).and_return(member) # Mock find to return the double
          expect(member).to receive(:send_renewal_slack_message)
          put :update, params: {id: member.to_param, renew: 10 }, format: :json
          expected_renewal = conv_to_ms(initial_expiration + 10.months)
          member.reload
          expect(member.expirationTime).to eq(expected_renewal)
        end

        it "updates the Slack profile when status changes" do
          slack_admin_token = require_env!("SLACK_ADMIN_TOKEN")
          slack_profile_status = require_env!("SLACK_PROFILE_STATUS")

          member = Member.create valid_attributes.merge(expirationTime: ((Time.now + 1.month).to_i * 1000))
          SlackUser.create!(
            member: member,
            slack_id: "U12345678",
            name: "slack.name",
            real_name: "Slack Name"
          )

          client = instance_double(Slack::Web::Client)
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_ADMIN_TOKEN").and_return(slack_admin_token)
          allow(ENV).to receive(:[]).with("SLACK_PROFILE_STATUS").and_return(slack_profile_status)
          allow(Slack::Web::Client).to receive(:new).and_return(client)
          allow(client).to receive(:users_profile_set)

          travel_to(Time.zone.parse("2026-05-31 12:00:00")) do
            put :update, params: { id: member.to_param, status: "suspended" }, format: :json
          end

          expect(client).to have_received(:users_profile_set).with(
            user: "U12345678",
            profile: {
              slack_profile_status => { value: "suspended" }
            }
          )
        end

        it "invalidates active sessions when suspending a member" do
          member = Member.create valid_attributes.merge(status: "activeMember", session_token: "current-token")
          put :update, params: { id: member.to_param, status: "suspended" }, format: :json
          expect(response).to have_http_status(200)
          expect(member.reload.session_token).not_to eq("current-token")
        end

        it "logs the status transition in field_changes, not the session_token rotation" do
          member = Member.create valid_attributes.merge(status: "activeMember", session_token: "current-token")

          expect(Service::AuditLogger).to receive(:log) do |**kwargs|
            expect(kwargs[:field_changes]).to have_key("status")
            expect(kwargs[:field_changes]["status"]).to eq(["activeMember", "suspended"])
            expect(kwargs[:field_changes]).not_to have_key("session_token")
          end.and_call_original

          put :update, params: { id: member.to_param, status: "suspended" }, format: :json
          expect(response).to have_http_status(200)
        end

        it "does not persist session_token in the audit log entry even if a caller fails to exclude it" do
          member = Member.create valid_attributes.merge(status: "activeMember", session_token: "current-token")
          put :update, params: { id: member.to_param, status: "suspended" }, format: :json

          entry = AuditLog.where(resource_id: member.id, event_type: "member_updated").last
          expect(entry).to be_present
          expect(entry.field_changes).not_to have_key("session_token")
          expect(entry.slack_message).not_to include("current-token")
        end

        it "updates the Slack profile fullname when names change" do
          slack_admin_token = require_env!("SLACK_ADMIN_TOKEN")
          slack_profile_fullname = require_env!("SLACK_PROFILE_FULLNAME")

          member = Member.create valid_attributes.merge(expirationTime: ((Time.now + 1.month).to_i * 1000))
          SlackUser.create!(
            member: member,
            slack_id: "U12345679",
            name: "slack.name",
            real_name: "Slack Name"
          )

          client = instance_double(Slack::Web::Client)
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_ADMIN_TOKEN").and_return(slack_admin_token)
          allow(ENV).to receive(:[]).with("SLACK_PROFILE_FULLNAME").and_return(slack_profile_fullname)
          allow(Slack::Web::Client).to receive(:new).and_return(client)
          allow(client).to receive(:users_profile_set)

          put :update, params: { id: member.to_param, firstname: "New", lastname: "Name" }, format: :json

          expect(client).to have_received(:users_profile_set).with(
            user: "U12345679",
            profile: {
              slack_profile_fullname => { value: "New Name (slack.name)" }
            }
          )
        end
      end

      context "with invalid params" do
        invalid_params = {
          firstname: 'Test',
          email: 'test@test.com',
          role: "foo"
        }

        before(:each) do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return("true")
        end

        it "raises validation error with invalid params" do
          member = Member.create valid_attributes
          put :update, params: invalid_params.merge({ id: member.to_param }), format: :json

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(422)
          expect(parsed_response['message']).to match(/Role/)
        end

        it "raises not found if member doens't exist" do
          put :update, params: {id: "foo" }, format: :json
          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(404)
        end
      end
    end
  end
end
