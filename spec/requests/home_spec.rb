require 'rails_helper'

RSpec.describe 'Member home', type: :request do
  before { allow(REDIS).to receive(:set).and_return(true) }

  def expect_no_authentication_alerts
    expect(REDIS).not_to receive(:set)
    expect(SlackMessagesJob).not_to receive(:perform_later)
    expect(Service::SlackConnector).not_to receive(:enque_message)
    expect(Service::SlackConnector).not_to receive(:client)
  end

  def expect_authentication_required
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.parsed_body).to eq('status' => 401, 'error' => 'unauthorized',
      'message' => 'Authentication failed. Review credentials and try again.')
  end

  it 'returns only the signed-in member, even for staff and when another ID is supplied' do
    member = create(:member, :admin, :current)
    other = create(:member, :current)
    sign_in member
    get '/api/home', params: { member_id: other.id.to_s }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('member', 'id')).to eq(member.id.to_s)
    expect(response.parsed_body.fetch('member')).not_to have_key('provisioning')
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  it 'rejects repeated anonymous requests without alert work' do
    expect_no_authentication_alerts
    2.times do
      get '/api/home', as: :json
      expect_authentication_required
    end
  end

  it 'rejects expired sessions without alert work or losing the private cache header' do
    member = create(:member, :current)
    sign_in member
    get '/api/home', as: :json
    expect(response).to have_http_status(:ok)

    expect_no_authentication_alerts
    travel(member.timeout_in + 1.second) do
      get '/api/home', as: :json
      expect_authentication_required
    end
  end

  it 'rejects expired TOTP challenges without alert work or losing the private cache header' do
    member = create(:member, password: 'password123', otp_required_for_login: true, otp_secret_encrypted: 'test-secret')
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123' } }, as: :json
    expect(response).to have_http_status(:accepted)

    expect_no_authentication_alerts
    travel 11.minutes do
      get '/api/home', as: :json
      expect_authentication_required
    end
  end

  [nil, 'T123'].each do |workspace_id|
    it "does not resolve Slack URLs while serializing Home with cached workspace #{workspace_id.inspect}" do
      member = create(:member, :current)
      SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email, real_name: 'Slack Member')
      member.reload.set(provisioning_email: member.email, slack_joined_at: Time.current, slack_acceptance_pending: false)
      sign_in member

      allow(Service::SlackConnector).to receive(:slack_team_id).and_return(workspace_id)
      allow(Service::SlackConnector).to receive(:new_members_channel).and_return('new_members')
      expect(Service::SlackConnector).not_to receive(:slack_user_url)
      expect(Service::SlackConnector).not_to receive(:init_team_id)
      expect(Service::SlackConnector).not_to receive(:client)

      get '/api/home', as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('member', 'slack')).to include(
        'slackId' => 'U123', 'name' => 'Slack Member', 'url' => nil
      )
      expect(response.parsed_body.fetch('slack')).to eq(
        'accepted' => true,
        'newMembersChannelUrl' => workspace_id ? 'https://slack.com/app_redirect?team=T123&channel=new_members' : nil
      )
    end
  end

  it 'withholds Home until a password login completes its TOTP challenge' do
    member = create(:member, password: 'password123', otp_required_for_login: true, otp_secret_encrypted: 'test-secret')
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123' } }, as: :json
    expect(response).to have_http_status(:accepted)
    expect_no_authentication_alerts
    get '/api/home', as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq('error' => 'TOTP verification required.')
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  it 'keeps Home invoice requests scoped to the member and excludes paid and upcoming invoices' do
    member = create(:member, :admin, :current)
    sign_in member
    # Seed existing invoice states directly: the create-time duplicate-membership
    # validation and payment/email callbacks are unrelated to this read contract.
    invoices = [
      build(:invoice, member: member, due_date: 1.day.ago),
      build(:invoice, member: member, subscription_id: 'sub123', due_date: 1.minute.ago),
      build(:invoice, member: member, settled_at: Time.current, due_date: 1.day.ago),
      build(:invoice, member: member, transaction_id: 'paid123', due_date: 1.day.ago),
      build(:invoice, member: create(:member), due_date: 1.day.ago),
      build(:invoice, member: member, due_date: 1.day.from_now)
    ]
    invoices.each { |invoice| Invoice.collection.insert_one(invoice.attributes) }
    get '/api/invoices', params: { settled: false, pastDue: true, orderBy: 'due_date', order: 'asc' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('id')).to contain_exactly(*invoices.first(2).map { |invoice| invoice.id.to_s })
  end

  it 'removes a repeatable task and event from Home after claiming and joining them' do
    member = create(:member, :current)
    task = VolunteerTask.create!(title: 'Organize supplies', description: 'Sort bins', status: 'repeatable')
    event = VolunteerEvent.create!(title: 'Open house', event_date: Date.tomorrow)
    sign_in member
    allow(Service::SlackConnector).to receive(:send_slack_message)
    get '/api/home'
    expect(response.parsed_body.fetch('availableVolunteerOpportunities').pluck('id')).to contain_exactly(task.id.to_s, event.id.to_s)

    post "/api/volunteer/tasks/#{task.id}/claim"
    expect(response).to have_http_status(:ok)
    post "/api/volunteer/events/#{event.id}/checkin"
    expect(response).to have_http_status(:ok)

    get '/api/home'
    expect(response.parsed_body.fetch('availableVolunteerOpportunities')).to be_empty
  end
end
