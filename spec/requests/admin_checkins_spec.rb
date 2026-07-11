require 'rails_helper'

RSpec.describe 'Admin checkins', type: :request do
  let(:member)       { create(:member) }
  let(:other_member) { create(:member) }
  let!(:member_card) { create(:card, member: member, uid: 'member-card-uid') }
  let!(:other_card)  { create(:card, member: other_member, uid: 'other-card-uid') }
  let(:checkins_collection) { Mongoid.default_client[:checkins] }

  before do
    checkins_collection.insert_many([
      { uid: member_card.uid, time: 1_700_000_000_000, timeOf: Time.at(1_700_000_000) },
      { uid: other_card.uid, time: 1_700_000_001_000, timeOf: Time.at(1_700_000_001) }
    ])
  end

  after do
    checkins_collection.delete_many({})
  end

  def request_checkins(uids)
    get '/api/admin/checkins', params: { uids: uids.to_json }
  end

  context 'as a regular member' do
    before { sign_in member }

    it 'ignores requested cards not held by the member and redacts returned UIDs' do
      request_checkins([other_card.uid])

      expect(response).to have_http_status(:ok)
      checkins = JSON.parse(response.body).fetch('checkins')
      expect(checkins).to be_empty
    end

    it 'redacts the UID to a stable, non-raw value for the same card across repeated requests' do
      request_checkins([member_card.uid])
      first_uid = JSON.parse(response.body).fetch('checkins').first.fetch('uid')

      request_checkins([member_card.uid])
      second_uid = JSON.parse(response.body).fetch('checkins').first.fetch('uid')

      expect(first_uid).not_to eq(member_card.uid)
      expect(first_uid).to eq(second_uid)
    end
  end

  shared_examples 'privileged checkin access' do |role|
    let(:actor) { create(:member, :"#{role}") }

    before { sign_in actor }

    it "allows #{role} members to query the requested UID range and returns raw UIDs" do
      request_checkins([member_card.uid, other_card.uid])

      expect(response).to have_http_status(:ok)
      uids = JSON.parse(response.body).fetch('checkins').map { |checkin| checkin.fetch('uid') }
      expect(uids).to contain_exactly(member_card.uid, other_card.uid)
    end
  end

  include_examples 'privileged checkin access', :resource_manager
  include_examples 'privileged checkin access', :admin
  include_examples 'privileged checkin access', :board_member
end
