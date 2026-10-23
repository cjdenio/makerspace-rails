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

  def request_checkins(uids, time_range: {})
    get '/api/admin/checkins', params: { uids: uids.to_json }.merge(time_range)
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

  describe 'time range filtering' do
    let(:admin) { create(:member, :admin) }

    before do
      checkins_collection.delete_many({})
      sign_in admin
    end

    it 'excludes checkins outside the requested startTime/endTime window' do
      now = Time.now
      in_range_uid = 'in-range-card'
      out_of_range_uid = 'out-of-range-card'
      checkins_collection.insert_many([
        { uid: in_range_uid, timeOf: now - 1.hour, time: ((now - 1.hour).to_f * 1000) },
        { uid: out_of_range_uid, timeOf: now - 30.days, time: ((now - 30.days).to_f * 1000) }
      ])

      # camelCase, exactly as the frontend sends via URLSearchParams
      request_checkins([in_range_uid, out_of_range_uid], time_range: {
        startTime: ((now - 7.days).to_i * 1000).to_s,
        endTime: (now.to_i * 1000).to_s
      })

      expect(response).to have_http_status(:ok)
      uids = JSON.parse(response.body).fetch('checkins').map { |checkin| checkin.fetch('uid') }
      expect(uids).to contain_exactly(in_range_uid)
    end
  end
end
