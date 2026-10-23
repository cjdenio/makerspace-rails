require 'rails_helper'

RSpec.describe Admin::RejectionsController, type: :controller do
  let(:admin) { create(:member, :admin) }
  let(:card) { create(:card, member: admin) }

  before(:each) do
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in admin
  end

  describe "GET #index" do
    it "caps results at the default limit" do
      600.times { |i| create(:rejection_card, uid: card.uid, timeOf: i.seconds.ago) }

      get :index, params: { uids: [card.uid].to_json }, format: :json
      parsed_response = JSON.parse(response.body)

      expect(response).to have_http_status(200)
      expect(parsed_response['rejections'].length).to eq(Admin::RejectionsController::DEFAULT_LIMIT)
    end

    it "honors a custom limit param" do
      5.times { |i| create(:rejection_card, uid: card.uid, timeOf: i.seconds.ago) }

      get :index, params: { uids: [card.uid].to_json, limit: "2" }, format: :json
      parsed_response = JSON.parse(response.body)

      expect(response).to have_http_status(200)
      expect(parsed_response['rejections'].length).to eq(2)
    end

    it "rejects a non-positive limit" do
      get :index, params: { uids: [card.uid].to_json, limit: "-1" }, format: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)['message']).to match(/positive integer/i)
    end

    it "returns the most recent rejections first" do
      older = create(:rejection_card, uid: card.uid, timeOf: 1.hour.ago)
      newer = create(:rejection_card, uid: card.uid, timeOf: 1.minute.ago)

      get :index, params: { uids: [card.uid].to_json }, format: :json
      parsed_response = JSON.parse(response.body)

      expect(parsed_response['rejections'].first['_id']).to eq(newer.id.to_s)
      expect(parsed_response['rejections'].last['_id']).to eq(older.id.to_s)
    end
  end
end
