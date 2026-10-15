require 'swagger_helper'

describe 'Mobile authentication', type: :request do
  let(:member) { create(:member, password: 'password123') }
  let(:'User-Agent') { 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148' }
  let(:secret) { TotpService.generate_secret }
  before { allow(REDIS).to receive(:set).and_return(true) }

  path '/auth/firebase_login' do
    post 'Sign in with a Firebase provider credential' do
      tags 'Authentication'
      operationId 'firebaseLogin'
      consumes 'application/json'
      produces 'application/json'
      description 'Public login with CSRF protection. rememberMe defaults to false and only enables persistence on phone clients after any required TOTP challenge or enrollment. Failed provider authentication preserves an existing remember cookie and pending persistence choice. Successful provider authentication replaces stale TOTP challenge state with the authenticated account\'s requirements and applies its own persistence choice.'
      parameter name: :'User-Agent', in: :header, required: false, schema: { type: :string }
      parameter name: :credentials, in: :body, required: true, schema: {
        type: :object, required: ['id_token'], properties: {
          id_token: { type: :string }, rememberMe: { type: :boolean, default: false }
        }
      }
      let(:credentials) { { id_token: 'provider-token', rememberMe: true } }
      before do
        allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(
          'sub' => 'provider-member', 'email' => member.email, 'email_verified' => true
        )
      end

      response '200', 'Member session established; enrollment may still be required' do
        schema allOf: [
          { '$ref' => '#/components/schemas/Member' },
          { type: :object, properties: { totp_enrollment_required: { type: :boolean } } }
        ]
        run_test! { expect(cookies['remember_member_token']).to be_present }
        context 'desktop' do
          let(:'User-Agent') { 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
          run_test! { expect(cookies['remember_member_token']).to be_blank }
        end
      end

      response '202', 'TOTP verification required' do
        schema type: :object, required: ['totp_required'], properties: { totp_required: { type: :boolean } }
        before { member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(secret)) }
        run_test! { expect(cookies['remember_member_token']).to be_blank }
      end

      response '400', 'Missing provider token' do
        let(:credentials) { {} }
        schema type: :object, properties: { message: { type: :string } }
        run_test!
      end

      response '401', 'Invalid provider credential or ineligible member' do
        before { allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(nil) }
        schema type: :object, properties: { message: { type: :string } }
        run_test!
      end
    end
  end

  path '/members/totp_sessions' do
    post 'Complete a pending login TOTP challenge' do
      tags 'Authentication'
      operationId 'completeTotpLogin'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      description 'Requires the pending authenticated session and CSRF token. Issues a remember cookie only when phone persistence was requested in the original login.'
      parameter name: :'User-Agent', in: :header, required: false, schema: { type: :string }
      parameter name: :verification, in: :body, required: true, schema: {
        type: :object, required: ['code'], properties: { code: { type: :string } }
      }
      let(:verification) { { code: ROTP::TOTP.new(secret).now } }
      before do
        member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(secret))
        post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123', rememberMe: true } },
          headers: { 'User-Agent' => send(:'User-Agent') }, as: :json
      end
      response '200', 'TOTP verified and login completed' do
        schema '$ref' => '#/components/schemas/Member'
        run_test! { expect(cookies['remember_member_token']).to be_present }
      end
      response '422', 'Invalid code' do
        let(:verification) { { code: 'invalid' } }
        schema type: :object, properties: { error: { type: :string } }
        run_test! { expect(cookies['remember_member_token']).to be_blank }
      end
      response '401', 'Missing or expired pending session' do
        before { reset! }
        run_test!
      end
    end
  end

  path '/members/totp/verify' do
    post 'Verify and activate TOTP enrollment' do
      tags 'Authentication'
      operationId 'verifyTotpEnrollment'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      description 'Requires a signed-in member, CSRF token, and a secret from /members/totp/setup. Completes deferred phone persistence after required enrollment.'
      parameter name: :'User-Agent', in: :header, required: false, schema: { type: :string }
      parameter name: :verification, in: :body, required: true, schema: {
        type: :object, required: ['code'], properties: { code: { type: :string } }
      }
      before do
        member.update!(role: 'admin')
        allow(SystemConfig).to receive(:enabled?).and_call_original
        allow(SystemConfig).to receive(:enabled?).with('require_totp_admin').and_return(true)
        post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123', rememberMe: true } },
          headers: { 'User-Agent' => send(:'User-Agent') }, as: :json
        post '/api/members/totp/setup', headers: { 'User-Agent' => send(:'User-Agent') }, as: :json
        @enrollment_secret = response.parsed_body.fetch('secret')
      end
      let(:verification) { { code: ROTP::TOTP.new(@enrollment_secret).now } }
      response '200', 'TOTP enrollment completed' do
        schema type: :object, properties: { message: { type: :string } }
        run_test! { expect(cookies['remember_member_token']).to be_present }
      end
      response '422', 'Invalid code or missing setup secret' do
        let(:verification) { { code: 'invalid' } }
        schema type: :object, properties: { error: { type: :string } }
        run_test!
      end
      response '401', 'Unauthenticated member' do
        before { reset! }
        let(:verification) { { code: '123456' } }
        run_test!
      end
    end
  end
end
