require 'rails_helper'

RSpec.describe EarnedMemberships::ReportsController, type: :controller do
  describe "Authenticated" do
    let!(:current_user) { create(:member) }
    let!(:membership) { create(:earned_membership_with_reports, member: current_user) }

    set_devise_mapping

    describe "GET index" do
      it "Raises 403 if current user isn't an earned member" do
        new_user = create(:member)
        sign_in new_user
        get :index, params: { earned_membership_id: membership.id }, format: :json
        expect(response).to have_http_status(403)
      end

      it "Renders the current user's reports as json" do
        sign_in current_user
        get :index, params: { earned_membership_id: membership.id }, format: :json
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        parsed_response = JSON.parse(response.body)
        expect(parsed_response.map { |r| r['id'] }).to match_array(
          EarnedMembership::Report.where(earned_membership_id: membership.id).pluck(:id).map(&:as_json)
        )
      end
    end

    describe "POST create" do
      let(:report_requirements) {
        [{
          requirement_id: membership.requirements.first.id,
          reported_count: 1
        }]
      }

      it "Raises 403 if current user isn't an earned member" do
        new_user = create(:member)
        sign_in new_user
        post :create, params: { earned_membership_id: membership.id, report_requirements: report_requirements }, format: :json
        expect(response).to have_http_status(403)
      end

       it "Raises 403 if creating report for someone elses membership" do
        sign_in current_user
        other_membership = create(:earned_membership)
        report_params = {
          earned_membership_id: other_membership.id,
          report_requirements: report_requirements
        }
        post :create, params: report_params, format: :json
        expect(response).to have_http_status(403)
      end

      it "Raises 422 if no report requirements submitted with report" do
        sign_in current_user
        report_params = {
          earned_membership_id: membership.id,
        }
        post :create, params: report_params, format: :json
        expect(response).to have_http_status(422)
      end

      it "Creates and returns new report with valid params" do
        sign_in current_user
        report_params = {
          earned_membership_id: membership.id,
          report_requirements: report_requirements
        }
        post :create, params: report_params, format: :json
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        parsed_response = JSON.parse(response.body)
        expect(parsed_response['id']).to eq(EarnedMembership::Report.last.id.as_json)
      end

      it "Renews member if they have fallen behind reporting" do
        start_time = (Time.now - 5.months).to_i
        expired_user = create(:member, expirationTime: start_time * 1000)
        requirement = create(:requirement, target_count: 1, term_length: 1)
        own_membership = create(:earned_membership_no_requirements, member: expired_user, requirements: [requirement])

        # Simulate falling behind: expiration lapsed and the requirement's term window
        # already elapsed too, well before reporting.
        expired_user.update(expirationTime: start_time * 1000)
        requirement.current_term.update(start_date: Time.now - 6.months)
        expired_user.reload
        original_expiration = expired_user.expirationTime

        sign_in expired_user
        report_params = {
          earned_membership_id: own_membership.id,
          report_requirements: [{ requirement_id: requirement.id, reported_count: 1 }]
        }
        post :create, params: report_params, format: :json
        expired_user.reload
        expect(expired_user.expirationTime).to be > original_expiration
      end

      it "Renews member if submitted report within required timeline" do
        curr_user = create(:member, expirationTime: Time.now.to_i * 1000)
        requirement = create(:requirement, target_count: 1, term_length: 1)
        own_membership = create(:earned_membership_no_requirements, member: curr_user, requirements: [requirement])

        # Reset to a clearly-stale baseline so the post-report renewal is unambiguous.
        curr_user.update(expirationTime: Time.now.to_i * 1000)
        curr_user.reload
        original_expiration = curr_user.expirationTime

        sign_in curr_user
        report_params = {
          earned_membership_id: own_membership.id,
          report_requirements: [{ requirement_id: requirement.id, reported_count: 1 }]
        }
        post :create, params: report_params, format: :json
        curr_user.reload
        expect(curr_user.expirationTime).to be > original_expiration
      end
    end
  end

  describe "Unauth" do
    let!(:membership) { create(:earned_membership) }

    describe "GET index" do
      it "Rejects unauthenticsated requests" do
        get :index, params: { earned_membership_id: membership.id }, format: :json
        expect(response).to have_http_status(401)
      end
    end

    describe "POST create" do
      it "Rejects unauthenticsated requests" do
        post :create, params: { earned_membership_id: membership.id }, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end
end