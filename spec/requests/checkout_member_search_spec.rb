require 'rails_helper'

RSpec.describe 'Checkout member search', type: :request do
  let(:viewer) { create(:member, :admin) }

  before { sign_in viewer }

  it 'filters status and expiration in Mongo before pagination, including the exact boundary' do
    freeze_time do
      now = Time.now.to_i * 1000
      create_list(:member, FastQuery::ITEMS_PER_PAGE, firstname: 'Needle', status: 'pending')
      %w[inactive revoked suspended nonMember].each do |status|
        create(:member, firstname: 'Needle', status: status, expirationTime: now + 1000)
      end
      [nil, now - 1, now].each do |expiration|
        member = create(:member, firstname: 'Needle')
        member.set(expirationTime: expiration)
      end
      eligible = create(:member, firstname: 'Needle', expirationTime: now + 1000)
      collection = Member.collection
      allow(Member).to receive(:collection).and_return(collection)
      allow(collection).to receive(:aggregate).and_raise(Mongo::Error::OperationFailure.new('Atlas unavailable'))

      get '/api/members', params: { search: 'Needle', fully_active_unexpired: true }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |row| row['id'] }).to eq([eligible.id.to_s])
      expect(response.headers['total-items'].to_i).to eq(1)
    end
  end

  it 'keeps unfiltered searches unchanged' do
    pending = create(:member, firstname: 'Needle', status: 'pending')
    get '/api/members', params: { search: 'Needle', fully_active_unexpired: false }
    expect(JSON.parse(response.body).map { |row| row['id'] }).to include(pending.id.to_s)
  end

  it 'does not broaden an ordinary member search' do
    viewer.update!(role: 'member')
    other = create(:member, :current, firstname: 'Needle')
    get '/api/members', params: { search: 'Needle', fully_active_unexpired: true }
    expect(JSON.parse(response.body).map { |row| row['id'] }).not_to include(other.id.to_s)
  end

  it 'passes eligibility and authorization criteria into Atlas search' do
    eligible = create(:member, :current, firstname: 'Needle')
    collection = Member.collection
    allow(Member).to receive(:collection).and_return(collection)
    expect(collection).to receive(:aggregate) do |pipeline|
      selector = pipeline.find { |stage| stage.key?(:$match) }.fetch(:$match)
      expect(selector['status']).to eq('activeMember')
      expect(selector['expirationTime']).to have_key('$gt')
      [{ _id: eligible.id }]
    end
    get '/api/members', params: { search: 'Needle', fully_active_unexpired: true }
    expect(JSON.parse(response.body).map { |row| row['id'] }).to eq([eligible.id.to_s])
  end
end
