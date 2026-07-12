require 'rails_helper'

# Regression coverage for the Firebase + TOTP login flow.
#
# This is a request spec (not a controller spec) specifically because the
# original bug here was a gap between routing and authentication state:
# FirebaseAuthController must establish enough session state to reach
# POST /api/members/totp_sessions, but that pending-TOTP session must not
# be accepted by normal authenticated or privileged routes before the
# challenge is completed. A controller spec for FirebaseAuthController alone
# would not catch this, since it doesn't exercise the route constraints and
# downstream authorization controllers.
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

    get '/api/config', as: :json

    expect(response).to have_http_status(:ok)

    get '/'

    expect(response).to have_http_status(:ok)

    # The pending session must not grant access to normal authenticated
    # routes until the TOTP challenge is completed.
    get "/api/members/#{member.id}", as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)).to eq('error' => 'TOTP verification required.')

    # The session set by the login request must still be enough to satisfy
    # authenticate :member on the totp_sessions route. Submitting a valid
    # code on the same session should succeed and clear the pending gate.
    valid_code = ROTP::TOTP.new(totp_secret).now
    post '/api/members/totp_sessions', params: { code: valid_code }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['email']).to eq(email)
    expect(member.reload.id.to_s).to eq(JSON.parse(response.body)['id'])

    get "/api/members/#{member.id}", as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'does not allow a pending Firebase TOTP session to use admin privileges before verification' do
    admin = create(
      :member,
      :admin,
      email:                 email,
      firebase_uid:          firebase_uid,
      otp_required_for_login: true,
      otp_secret_encrypted:   TotpService.encrypt(totp_secret)
    )

    post '/api/auth/firebase_login', params: { id_token: 'firebase-token' }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(JSON.parse(response.body)).to eq('totp_required' => true)

    # Regression coverage for the bypass: this route only checks the Devise
    # session plus admin/board role, so a pending TOTP session must be stopped
    # by the global TOTP completion gate before AdminController authorizes it.
    get '/api/admin/cards/new', as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)).to eq('error' => 'TOTP verification required.')

    valid_code = ROTP::TOTP.new(totp_secret).now
    post '/api/members/totp_sessions', params: { code: valid_code }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['id']).to eq(admin.id.to_s)

    get '/api/admin/cards/new', as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'expires stale pending TOTP gates so Firebase login can issue a fresh challenge' do
    create(
      :member,
      email:                 email,
      firebase_uid:          firebase_uid,
      otp_required_for_login: true,
      otp_secret_encrypted:   TotpService.encrypt(totp_secret)
    )

    post '/api/auth/firebase_login', params: { id_token: 'firebase-token' }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(JSON.parse(response.body)).to eq('totp_required' => true)

    travel 11.minutes do
      post '/api/auth/firebase_login', params: { id_token: 'firebase-token' }, as: :json
    end

    expect(response).to have_http_status(:accepted)
    expect(JSON.parse(response.body)).to eq('totp_required' => true)
  end
end
