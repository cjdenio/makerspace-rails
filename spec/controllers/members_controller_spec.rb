require 'rails_helper'

RSpec.describe MembersController, type: :controller do
  describe "GET #index" do
    context "as an admin" do
      login_admin
      it "renders json of all members" do
        member = create(:member)
        get :index, params: {}, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        expect(parsed_response.last['id']).to eq(Member.last.id.as_json)
      end

      it "filters to current members when current_members param is true" do
        create(:member, :expired)
        create(:member, :current)
        get :index, params: { current_members: true }, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        parsed_response.each do |m|
          next if m['expirationTime'].nil?
          expect(m['expirationTime']).to be >= ((Time.now).to_i * 1000)
        end
      end
    end

    context "as a resource manager" do
      login_resource_manager

      it "renders json of all members" do
        member = create(:member)
        get :index, params: {}, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        expect(parsed_response).not_to be_empty
      end

      it "can search members by name" do
        create(:member, firstname: "Unique", lastname: "Findable")
        get :index, params: { search: "Findable" }, format: :json

        expect(response).to have_http_status(200)
      end

      it "returns more than just the current member" do
        create_list(:member, 3)
        get :index, params: {}, format: :json

        parsed_response = JSON.parse(response.body)
        expect(parsed_response.length).to be > 1
      end
    end

    context "as a regular member" do
      let!(:current_user) { create(:member) }
      before(:each) do
        @request.env["devise.mapping"] = Devise.mappings[:member]
        sign_in current_user
      end

      it "returns only the current member's own record" do
        create(:member) # another member that should NOT appear
        get :index, params: {}, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(parsed_response.length).to eq(1)
        expect(parsed_response.first['id']).to eq(current_user.id.as_json)
      end

      it "does not return other members even when searching" do
        other = create(:member, firstname: "Other", lastname: "Person")
        # Search for current_user's name to ensure only their record comes back
        get :index, params: { search: current_user.firstname }, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        # Regular members only see themselves regardless of search term
        expect(parsed_response.map { |m| m['id'] }).not_to include(other.id.as_json)
      end
    end

    context "when unauthenticated" do
      it "returns 401" do
        get :index, params: {}, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end

  describe "GET #show" do
    login_user
    it "renders json of the retrieved member" do
      get :show, params: {id: current_user.to_param}, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      expect(parsed_response['id']).to eq(current_user.id.as_json)
    end

    it "raises not found if member doesn't exist" do
      get :show, params: {id: "foo" }, format: :json
      expect(response).to have_http_status(404)
    end
    
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
  end

  describe "PUT #update" do
    let!(:current_user) { create(:member) }
    member_params = {
      firstname: "foo"
    }
    before(:each) do
      sign_in current_user
    end

    it "renders json of the updated member" do
      member_params = {
        firstname: "foo"
      }
      put :update, params: member_params.merge({ id: current_user.id }), format: :json
      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['id']).to eq(current_user.id.as_json)
      expect(parsed_response['firstname']).to eq("foo")
    end

    it "Updates member's address properly" do
      member_params = {
        phone: "5559021",
        address: {
          street: "12 Main St.",
          unit: "4",
          city: "Roswell",
          state: "NM",
          postal_code: "00666"
        }
      }

      put :update, params: member_params.merge({ id: current_user.id }), format: :json
      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['phone']).to eq(member_params[:phone])
      expect(parsed_response['address']['street']).to eq(member_params[:address][:street])
      expect(parsed_response['address']['unit']).to eq(member_params[:address][:unit])
      expect(parsed_response['address']['city']).to eq(member_params[:address][:city])
      expect(parsed_response['address']['state']).to eq(member_params[:address][:state])
      expect(parsed_response['address']['postalCode']).to eq(member_params[:address][:postal_code])
    end

    it "Updates member's notification settings" do
      put :update, params: { id: current_user.id, silenceEmails: true }, format: :json
      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['silenceEmails']).to be_truthy
    end

    it "raises forbidden if not updating current member" do
      member = create(:member)
      put :update, params: { id: member.id, member: member_params }, format: :json
      expect(response).to have_http_status(403)
    end

    it "raises not found if member doesn't exist" do
      put :update, params: {id: "foo" }, format: :json
      expect(response).to have_http_status(404)
    end
  end
end
