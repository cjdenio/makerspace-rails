require 'rails_helper'

# Regression coverage for the Firebase + TOTP login flow.
#
# This is a request spec (not a controller spec) specifically because the
# original bug here was a gap between routing and authentication state:
# the TOTP gate in FirebaseAuthController was firing before sign_in, so a
# TOTP-enrolled member could never establish a session and therefore could
# never reach POST /api/members/totp_sessions to complete the challenge
# (that route requires an authenticated member). A controller spec for
# FirebaseAuthController alone would not catch this, since it doesn't
# exercise the actual route constraint on TotpSessionsController.
RSpec.describe 'Firebase TOTP login flow', type: :request do
  let(:firebase_uid) { 'firebase-uid-456' }
  let(:email)        { 'firebase-totp-member@example.com' }
  let(:totp_secret)  { TotpService.generate_secret }
  let(:payload) do
    {
      'sub'            => firebase_uid,
      'email'          => email,
      'email_verified' => true,
      'name'           => 'Firebase Totp Member'
    }
  end

  before do
    allow_any_instance_of(FirebaseAuthController)
      .to receive(:verify_firebase_token).and_return(payload)
  end

  it 'establishes a session on the TOTP challenge and allows completing it via /totp_sessions' do
    member = create(
      :member,
      email:                 email,
      firebase_uid:          firebase_uid,
      otp_required_for_login: true,
      otp_secret_encrypted:   TotpService.encrypt(totp_secret)
    )

    post '/api/auth/firebase_login', params: { id_token: 'firebase-token' }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(JSON.parse(response.body)).to eq('totp_required' => true)

    # The critical assertion: the session set by the login request must be
    # enough to satisfy authenticate :member on the totp_sessions route.
    # Submitting a valid code on the same session should succeed.
    valid_code = ROTP::TOTP.new(totp_secret).now
    post '/api/members/totp_sessions', params: { code: valid_code }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['email']).to eq(email)
    expect(member.reload.id.to_s).to eq(JSON.parse(response.body)['id'])
  end
end
