require 'rails_helper'

RSpec.describe Admin::SlackIdentityConflictsController, type: :controller do
  set_devise_mapping

  let(:admin)  { create(:member, role: 'admin') }
  let(:member) { create(:member) }

  before { sign_in admin }

  describe "GET #index" do
    it "returns the conflicts detected by the sync service" do
      allow(Service::SlackUserSync).to receive(:detect_conflicts).and_return(
        [{ slack_id: 'UNEW', member_id: member.id.to_s, member_name: member.fullname }]
      )

      get :index, format: :json

      expect(response).to have_http_status(200)
      parsed = JSON.parse(response.body)
      expect(parsed['conflicts'].first).to include('slack_id' => 'UNEW', 'member_id' => member.id.to_s)
    end
  end

  describe "POST #reassign" do
    it "reassigns the identity and returns the linked member" do
      allow(Service::SlackUserSync).to receive(:reassign_identity)
        .with(slack_id: 'UNEW', member_id: member.id.to_s, actor: admin)
        .and_return(member)

      post :reassign, params: { slack_id: 'UNEW', member_id: member.id.to_s }, format: :json

      expect(response).to have_http_status(200)
      parsed = JSON.parse(response.body)
      expect(parsed['member_id']).to eq(member.id.to_s)
      expect(parsed['message']).to include('UNEW')
    end

    it "requires slack_id and member_id" do
      post :reassign, params: { slack_id: 'UNEW' }, format: :json

      expect(response).to have_http_status(422)
    end
  end

  describe "POST #dismiss" do
    it "dismisses the conflicting identity and returns the member" do
      allow(Service::SlackUserSync).to receive(:dismiss_conflict)
        .with(slack_id: 'UNEW', member_id: member.id.to_s, slack_email: 'unew@example.com', slack_name: 'Duplicate', actor: admin)
        .and_return(member)

      post :dismiss, params: {
        slack_id: 'UNEW', member_id: member.id.to_s, slack_email: 'unew@example.com', slack_name: 'Duplicate'
      }, format: :json

      expect(response).to have_http_status(200)
      parsed = JSON.parse(response.body)
      expect(parsed['member_id']).to eq(member.id.to_s)
      expect(parsed['message']).to include('UNEW')
    end

    it "requires slack_id and member_id" do
      post :dismiss, params: { slack_id: 'UNEW' }, format: :json

      expect(response).to have_http_status(422)
    end
  end

  describe "authorization" do
    it "rejects a non-admin, non-board member" do
      sign_in member

      get :index, format: :json

      expect(response).to have_http_status(403)
    end
  end
end
