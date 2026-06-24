require 'rails_helper'

RSpec.describe FirebaseAuthController, type: :controller do
  set_devise_mapping

  let(:firebase_uid) { 'firebase-uid-123' }
  let(:email) { 'firebase-member@example.com' }
  let(:payload) do
    {
      'sub' => firebase_uid,
      'email' => email,
      'email_verified' => true,
      'name' => 'Firebase Member'
    }
  end

  before do
    allow(controller).to receive(:verify_firebase_token).and_return(payload)
  end

  describe 'POST #login' do
    it 'requires TOTP verification before signing in a member with TOTP enabled' do
      member = create(:member, email: email, otp_required_for_login: true, otp_secret_encrypted: 'encrypted-secret')

      post :login, params: { id_token: 'firebase-token' }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)).to eq('totp_required' => true)
      expect(session[:totp_pending_member_id]).to eq(member.id.to_s)
      expect(session[:totp_pending_expires_at]).to be_present
      # A real Devise session exists at this point — sign_in runs before the
      # TOTP gate, matching SessionsController's password-login order. The
      # session is fully established; it's the app/UI layer that should
      # treat the member as not-yet-fully-authenticated based on the
      # totp_required flag, not the controller's session state.
      expect(controller.current_member).to eq(member)
    end

    it 'preserves role-based TOTP enrollment prompts for Firebase sign-in' do
      member = create(:member, :admin, email: email, otp_required_for_login: false)
      allow(SystemConfig).to receive(:enabled?).and_call_original
      allow(SystemConfig).to receive(:enabled?).with('require_totp_admin').and_return(true)

      post :login, params: { id_token: 'firebase-token' }, format: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['totp_enrollment_required']).to eq(true)
      expect(controller.current_member).to eq(member)
    end
  end
end
