require 'rails_helper'

RSpec.describe EarnedMemberships::ReportsController, type: :controller do
  set_devise_mapping

  let!(:current_user) { create(:member) }
  let!(:membership) { create(:earned_membership, member: current_user) }
  let(:report_requirements) {
    [{
      requirement_id: membership.requirements.first.id,
      reported_count: 1
    }]
  }

  before { sign_in current_user }

  describe "GET index while suspended" do
    it "still allows viewing report history for a suspended earned membership" do
      membership.suspend!(create(:member, :admin))
      get :index, params: { earned_membership_id: membership.id }, format: :json
      expect(response).to have_http_status(200)
    end
  end

  describe "POST create while suspended" do
    it "rejects submitting a new report for a suspended earned membership" do
      membership.suspend!(create(:member, :admin))
      post :create, params: {
        earned_membership_id: membership.id,
        report_requirements: report_requirements
      }, format: :json
      expect(response).to have_http_status(403)
    end

    it "allows submitting a report while the earned membership is active" do
      post :create, params: {
        earned_membership_id: membership.id,
        report_requirements: report_requirements
      }, format: :json
      expect(response).to have_http_status(200)
    end
  end
end
