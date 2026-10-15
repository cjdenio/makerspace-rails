require 'rails_helper'

RSpec.describe SessionsController, type: :controller do
  set_devise_mapping

  let(:password) { 'password123' }
  let(:member) do
    create(:member, email: 'totp-member@example.com', password: password,
      otp_required_for_login: true, otp_secret_encrypted: 'encrypted-secret')
  end

  describe 'POST #create' do
    it 'restores a completed authenticated session without another TOTP challenge' do
      sign_in member
      post :create, params: {}, format: :json
      expect(response).to have_http_status(:ok)
      expect(session[:totp_pending_member_id]).to be_nil
    end

    it 'does not restore a session with an unfinished TOTP challenge' do
      sign_in member
      session[:totp_pending_member_id] = member.id.to_s
      post :create, params: {}, format: :json
      expect(response).to have_http_status(:accepted)
    end

    it 'sets a pending TOTP challenge instead of fully signing in' do
      post :create, params: { member: { email: member.email, password: password } }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)).to eq('totp_required' => true)
      expect(session[:totp_pending_member_id]).to eq(member.id.to_s)
    end

    it 'does not deadlock on a second sign-in attempt while a TOTP challenge is already pending' do
      # First attempt: password correct, TOTP required. warden.authenticate!
      # establishes the Devise session before the pending state is set, so
      # member_signed_in? is already true here -- see #ensure_completed_totp_challenge.
      post :create, params: { member: { email: member.email, password: password } }, format: :json
      expect(response).to have_http_status(:accepted)

      # A second attempt (retry, second tab, race with the code-entry step)
      # must still be able to (re)start the flow rather than get rejected by
      # the TOTP gate before SessionsController#create even runs.
      post :create, params: { member: { email: member.email, password: password } }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)).to eq('totp_required' => true)
    end
  end
end
