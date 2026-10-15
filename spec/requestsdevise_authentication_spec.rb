require 'rails_helper'

RSpec.describe 'Devise member authentication', type: :request do
  let(:password) { 'password' }

  before do
    allow(::Service::SlackConnector).to receive(:send_slack_message)
  end

  it 'authenticates a member with Devise database authentication and persists current_member in the session' do
    member = create(:member, email: 'devise-member@example.com', encrypted_password: BCrypt::Password.create(password))

    post '/api/members/sign_in', params: { member: { email: member.email, password: password } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['email']).to eq(member.email)

    get "/api/members/#{member.id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['id']).to eq(member.id.as_json)
  end

  it 'rejects an invalid password using Devise/Warden failure handling' do
    member = create(:member, email: 'bad-password@example.com', encrypted_password: BCrypt::Password.create(password))

    post '/api/members/sign_in', params: { member: { email: member.email, password: 'incorrect' } }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)['message']).to eq('Invalid email or password.')
  end

  it 'blocks members whose Devise active_for_authentication? hook marks them inactive' do
    member = create(:member, :revoked, email: 'revoked-devise-member@example.com', encrypted_password: BCrypt::Password.create(password))

    post '/api/members/sign_in', params: { member: { email: member.email, password: password } }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)['message']).to eq('Login failed, email board@manchestermakerspace.org with error code R2026')
    expect(::Service::SlackConnector).to have_received(:send_slack_message)
  end
end
