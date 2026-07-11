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

      it "sorts members without expirationTime by startDate when ordering by expirationTime" do
        older_started_member = create(:member, expirationTime: nil, startDate: Time.zone.parse("2024-01-01"))
        newer_started_member = create(:member, expirationTime: nil, startDate: Time.zone.parse("2024-02-01"))
        expiring_member = create(:member, expirationTime: Time.zone.parse("2024-03-01").to_i * 1000)

        get :index, params: { order_by: "expirationTime", order: "asc" }, format: :json

        parsed_response = JSON.parse(response.body)
        sorted_ids = parsed_response.map { |member| member["id"] }
        expect(sorted_ids & [older_started_member.id.as_json, newer_started_member.id.as_json, expiring_member.id.as_json]).to eq([
          older_started_member.id.as_json,
          newer_started_member.id.as_json,
          expiring_member.id.as_json
        ])
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

    it "does not allow a regular member to clear their marketing email silence flag" do
      current_user.set(silence_emails: true)

      put :update, params: { id: current_user.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(403)
      expect(current_user.reload.silence_emails).to be true
    end

    it "skips silence email authorization when a regular member leaves their flag unchanged" do
      current_user.set(silence_emails: false)

      put :update, params: { id: current_user.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(200)
      expect(current_user.reload.silence_emails).to be false
    end

    it "raises forbidden if not updating current member" do
      member = create(:member)
      put :update, params: { id: member.id, member: member_params }, format: :json
      expect(response).to have_http_status(403)
    end

    it "raises forbidden when a resource manager updates another member" do
      resource_manager = create(:member, :resource_manager)
      member = create(:member)
      sign_in resource_manager

      put :update, params: { id: member.id, firstname: "Resource" }, format: :json

      expect(response).to have_http_status(403)
      expect(member.reload.firstname).not_to eq("Resource")
    end

    it "raises forbidden when a resource manager signs another member's contract" do
      resource_manager = create(:member, :resource_manager)
      member = create(:member, member_contract_signed_date: nil)
      sign_in resource_manager

      put :update, params: { id: member.id, signature: "data:image/png;base64,abc123" }, format: :json

      expect(response).to have_http_status(403)
      expect(member.reload.member_contract_signed_date).to be_nil
    end

    it "allows an admin to update another member" do
      admin = create(:member, :admin)
      member = create(:member)
      sign_in admin

      put :update, params: { id: member.id, firstname: "Admin" }, format: :json

      expect(response).to have_http_status(200)
      expect(member.reload.firstname).to eq("Admin")
    end

    it "allows a board member to update another member" do
      board_member = create(:member, :board_member)
      member = create(:member)
      sign_in board_member

      put :update, params: { id: member.id, firstname: "Board" }, format: :json

      expect(response).to have_http_status(200)
      expect(member.reload.firstname).to eq("Board")
    end

    it "raises not found if member doesn't exist" do
      put :update, params: {id: "foo" }, format: :json
      expect(response).to have_http_status(404)
    end
  end
  describe "PUT #update silence_emails authorization" do
    let(:member) { create(:member, silence_emails: false) }

    before(:each) do
      @request.env["devise.mapping"] = Devise.mappings[:member]
    end

    it "allows a board member to set another member's marketing email silence flag" do
      sign_in create(:member, :board_member)

      put :update, params: { id: member.id, silenceEmails: true }, format: :json

      expect(response).to have_http_status(200)
      expect(member.reload.silence_emails).to be true
    end

    it "does not allow a board member to clear another member's marketing email silence flag" do
      member.set(silence_emails: true)
      sign_in create(:member, :board_member)

      put :update, params: { id: member.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(403)
      expect(member.reload.silence_emails).to be true
    end

    it "skips silence email authorization when a board member leaves another member's flag unchanged" do
      sign_in create(:member, :board_member)

      put :update, params: { id: member.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(200)
      expect(member.reload.silence_emails).to be false
    end

    it "allows an admin to set and clear another non-revoked member's marketing email silence flag" do
      sign_in create(:member, :admin)

      put :update, params: { id: member.id, silenceEmails: true }, format: :json
      expect(response).to have_http_status(200)
      expect(member.reload.silence_emails).to be true

      put :update, params: { id: member.id, silenceEmails: false }, format: :json
      expect(response).to have_http_status(200)
      expect(member.reload.silence_emails).to be false
    end

    it "allows admins to set and clear their own marketing email silence flag" do
      admin = create(:member, :admin, silence_emails: false)
      sign_in admin

      put :update, params: { id: admin.id, silenceEmails: true }, format: :json
      expect(response).to have_http_status(200)
      expect(admin.reload.silence_emails).to be true

      put :update, params: { id: admin.id, silenceEmails: false }, format: :json
      expect(response).to have_http_status(200)
      expect(admin.reload.silence_emails).to be false
    end

    it "allows board members to set and clear their own marketing email silence flag" do
      board_member = create(:member, :board_member, silence_emails: false)
      sign_in board_member

      put :update, params: { id: board_member.id, silenceEmails: true }, format: :json
      expect(response).to have_http_status(200)
      expect(board_member.reload.silence_emails).to be true

      put :update, params: { id: board_member.id, silenceEmails: false }, format: :json
      expect(response).to have_http_status(200)
      expect(board_member.reload.silence_emails).to be false
    end

    it "allows resource managers to set and clear their own marketing email silence flag" do
      resource_manager = create(:member, :resource_manager, silence_emails: false)
      sign_in resource_manager

      put :update, params: { id: resource_manager.id, silenceEmails: true }, format: :json
      expect(response).to have_http_status(200)
      expect(resource_manager.reload.silence_emails).to be true

      put :update, params: { id: resource_manager.id, silenceEmails: false }, format: :json
      expect(response).to have_http_status(200)
      expect(resource_manager.reload.silence_emails).to be false
    end

    it "forbids a resource manager from updating another member at all, even a no-op silence_emails change" do
      sign_in create(:member, :resource_manager)

      put :update, params: { id: member.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(403)
      expect(member.reload.silence_emails).to be false
    end

    it "does not allow an admin to change a revoked member's marketing email silence flag" do
      revoked_member = create(:member, :revoked, silence_emails: true)
      sign_in create(:member, :admin)

      put :update, params: { id: revoked_member.id, silenceEmails: false }, format: :json

      expect(response).to have_http_status(403)
      expect(revoked_member.reload.silence_emails).to be true
    end
  end

end
