require 'rails_helper'

RSpec.describe Admin::CheckinsController, type: :controller do
  let(:admin) { create(:member, :admin) }
  let(:card) { create(:card, member: admin) }
  let(:checkins_collection) { Mongoid.default_client[:checkins] }

  before(:each) do
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in admin
  end

  after(:each) do
    checkins_collection.delete_many({})
  end

  describe "GET #index" do
    it "caps results at the default limit" do
      now_seconds = Time.now.to_i
      600.times do |i|
        checkins_collection.insert_one(uid: card.uid, timeOf: now_seconds - i)
      end

      get :index, params: { uids: [card.uid].to_json }, format: :json
      parsed_response = JSON.parse(response.body)

      expect(response).to have_http_status(200)
      expect(parsed_response['checkins'].length).to eq(Admin::CheckinsController::DEFAULT_LIMIT)
    end

    it "honors a custom limit param" do
      now_seconds = Time.now.to_i
      5.times { |i| checkins_collection.insert_one(uid: card.uid, timeOf: now_seconds - i) }

      get :index, params: { uids: [card.uid].to_json, limit: "2" }, format: :json
      parsed_response = JSON.parse(response.body)

      expect(response).to have_http_status(200)
      expect(parsed_response['checkins'].length).to eq(2)
    end

    it "rejects a non-positive limit" do
      get :index, params: { uids: [card.uid].to_json, limit: "0" }, format: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)['message']).to match(/positive integer/i)
    end

    it "returns the most recent checkins first despite mixed second/millisecond units" do
      now_seconds = Time.now.to_i
      # Stored in seconds (oldest), then milliseconds (newest) — a native Mongo
      # sort on the raw field would put these out of chronological order.
      checkins_collection.insert_one(uid: card.uid, timeOf: now_seconds - 100)
      checkins_collection.insert_one(uid: card.uid, timeOf: (now_seconds) * 1000)

      get :index, params: { uids: [card.uid].to_json }, format: :json
      parsed_response = JSON.parse(response.body)

      timestamps = parsed_response['checkins'].map { |c| c['timeOf'] }
      expect(timestamps.first).to eq(now_seconds * 1000)
      expect(timestamps.last).to eq(now_seconds - 100)
    end
  end
end
