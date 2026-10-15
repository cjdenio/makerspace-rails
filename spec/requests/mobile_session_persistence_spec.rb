require 'rails_helper'

RSpec.describe 'Mobile session persistence', type: :request do
  CLIENTS = JSON.parse(File.read(Rails.root.join('spec/fixtures/mobile_session_clients.json')))
  let(:phone) { CLIENTS.find { |client| client['name'] == 'iPhone Safari' }.fetch('agent') }
  let(:desktop) { CLIENTS.find { |client| client['name'] == 'Windows desktop' }.fetch('agent') }
  let(:password) { 'password123' }
  let(:member) { create(:member, password: password) }
  let(:secret) { TotpService.generate_secret }
  let(:remember_key) { 'remember_member_token' }
  let(:session_key) { '_member-interface_session' }

  before { allow(REDIS).to receive(:set).and_return(true) }

  def login(agent: phone, remember: true, provider: false)
    if provider
      allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(
        'sub' => 'mobile-provider', 'email' => member.email, 'email_verified' => true
      )
      post '/api/auth/firebase_login', params: { id_token: 'verified-token', rememberMe: remember },
        headers: { 'User-Agent' => agent }, as: :json
    else
      post '/api/members/sign_in', params: { member: { email: member.email, password: password, rememberMe: remember } },
        headers: { 'User-Agent' => agent }, as: :json
    end
  end

  def restore(agent: phone)
    cookies.delete(session_key)
    post '/api/members/sign_in', params: {}, headers: { 'User-Agent' => agent }, as: :json
  end

  CLIENTS.each do |client|
    it "classifies #{client['name']} identically to React and gates persistence" do
      expect(MobileSessionClient.phone?(client['agent'])).to eq(client['phone'])
      login(agent: client['agent'])
      expect(response).to have_http_status(:ok)
      expect(cookies[remember_key].present?).to eq(client['phone'])
    end
  end

  [false, nil].each do |choice|
    it "keeps normal idle timeout when rememberMe is #{choice.inspect}" do
      login(remember: choice)
      expect(response).to have_http_status(:ok)
      expect(cookies[remember_key]).to be_blank
      travel(member.timeout_in + 1.second) do
        get '/api/home', headers: { 'User-Agent' => phone }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  it 'does not remember an invalid password' do
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'wrong', rememberMe: true } },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(cookies[remember_key]).to be_blank
  end

  it 'does not upgrade an existing session or an old client that omits the choice' do
    post '/api/members/sign_in', params: { member: { email: member.email, password: password } },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:ok)
    post '/api/members/sign_in', params: {}, headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:ok)
    expect(cookies[remember_key]).to be_blank
  end

  it 'clears the current browser remember cookie when a subsequent login opts out' do
    login
    login(remember: false)
    expect(cookies[remember_key]).to be_blank
    restore
    expect(response).to have_http_status(:unauthorized)
  end

  [nil, '', 'wrong'].each do |submitted_password|
    it "requires a fresh password despite an existing ordinary session (#{submitted_password.inspect})" do
      login(remember: false)
      credentials = { email: member.email, rememberMe: true }
      credentials[:password] = submitted_password unless submitted_password.nil?
      post '/api/members/sign_in', params: { member: credentials }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(cookies[remember_key]).to be_blank
      restore
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'rejects a remember-only payload despite an existing session' do
    login(remember: false)
    post '/api/members/sign_in', params: { member: { rememberMe: true } }, headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(cookies[remember_key]).to be_blank
  end

  it 'allows an ordinary session to opt in after fresh valid credentials' do
    login(remember: false)
    login
    expect(response).to have_http_status(:ok)
    expect(cookies[remember_key]).to be_present
    restore
    expect(response).to have_http_status(:ok)
  end

  it 'authenticates the submitted account instead of the cached account' do
    login(remember: false)
    other = create(:member, password: 'other-password123')
    post '/api/members/sign_in', params: { member: { email: other.email, password: 'other-password123', rememberMe: true } },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['email']).to eq(other.email)
    restore
    expect(response.parsed_body['email']).to eq(other.email)
  end

  it 'rejects bad credentials even when a remember cookie has already restored the user' do
    login
    cookies.delete(session_key)
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'wrong', rememberMe: true } },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(cookies[remember_key]).to be_present
    restore
    expect(response).to have_http_status(:ok)
  end

  context 'when switching accounts during a pending TOTP challenge' do
    let(:other) { create(:member, password: 'other-password123') }

    before do
      member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(secret))
      login
      expect(response).to have_http_status(:accepted)
    end

    def switch_account(password: 'other-password123')
      post '/api/members/sign_in', params: { member: { email: other.email, password: password, rememberMe: true } },
        headers: { 'User-Agent' => phone }, as: :json
    end

    it 'clears the old challenge and rejects its code after authenticating a member without TOTP' do
      switch_account
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
      expect(request.session[:totp_pending_member_id]).to be_nil
      expect(request.session[:totp_pending_expires_at]).to be_nil
      get '/api/home', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:unauthorized)
      post '/api/members/sign_in', params: {}, headers: { 'User-Agent' => phone }, as: :json
      expect(response.parsed_body['email']).to eq(other.email)
      restore
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
    end

    it 'requires the new account challenge before granting persistence' do
      other_secret = TotpService.generate_secret
      other.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(other_secret))
      switch_account
      expect(response).to have_http_status(:accepted)
      expect(request.session[:totp_pending_member_id]).to eq(other.id.to_s)
      expect(cookies[remember_key]).to be_blank
      get '/api/home', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:unauthorized)
      post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(other_secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
      expect(cookies[remember_key]).to be_present
    end

    it 'preserves the original challenge when replacement credentials are invalid' do
      switch_account(password: 'wrong')
      expect(response).to have_http_status(:unauthorized)
      get '/api/home', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:unauthorized)
      post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(member.email)
    end

    it 'clears the old challenge while still requiring enrollment for the new account' do
      other.update!(role: 'admin')
      allow(SystemConfig).to receive(:enabled?).and_call_original
      allow(SystemConfig).to receive(:enabled?).with('require_totp_admin').and_return(true)
      switch_account
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['totp_enrollment_required']).to eq(true)
      expect(request.session[:totp_pending_member_id]).to be_nil
      expect(request.session[:totp_pending_expires_at]).to be_nil
      expect(cookies[remember_key]).to be_blank
      post '/api/members/totp/setup', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      enrollment_secret = response.parsed_body.fetch('secret')
      post '/api/members/totp/verify', params: { code: ROTP::TOTP.new(enrollment_secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      expect(cookies[remember_key]).to be_present
      restore
      expect(response.parsed_body['email']).to eq(other.email)
    end
  end

  context 'provider login with a stale challenge from an invalidated session' do
    let(:other) { create(:member) }

    before do
      member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(secret))
      login
      expect(response).to have_http_status(:accepted)
      # Invalidate Warden's serialized member while retaining the browser's
      # encrypted session, including its pending challenge fields.
      member.update!(session_token: SecureRandom.hex)
      allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(
        'sub' => 'replacement-provider', 'email' => other.email, 'email_verified' => true
      )
    end

    def provider_switch
      post '/api/auth/firebase_login', params: { id_token: 'replacement-token', rememberMe: true },
        headers: { 'User-Agent' => phone }, as: :json
    end

    it 'clears the old challenge and prevents its code from switching back to the old account' do
      provider_switch
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
      expect(request.session[:totp_pending_member_id]).to be_nil
      expect(request.session[:totp_pending_expires_at]).to be_nil
      get '/api/home', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:unauthorized)
      restore
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
    end

    it 'replaces the stale challenge with the provider account challenge before remembering it' do
      other_secret = TotpService.generate_secret
      other.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(other_secret))
      provider_switch
      expect(response).to have_http_status(:accepted)
      expect(request.session[:totp_pending_member_id]).to eq(other.id.to_s)
      expect(cookies[remember_key]).to be_blank
      post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(other_secret).now }, headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(other.email)
      expect(cookies[remember_key]).to be_present
    end

    it 'clears the old challenge while preserving the provider account enrollment requirement' do
      other.update!(role: 'admin')
      allow(SystemConfig).to receive(:enabled?).and_call_original
      allow(SystemConfig).to receive(:enabled?).with('require_totp_admin').and_return(true)
      provider_switch
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['totp_enrollment_required']).to eq(true)
      expect(request.session[:totp_pending_member_id]).to be_nil
      expect(request.session[:totp_pending_expires_at]).to be_nil
      expect(cookies[remember_key]).to be_blank
      post '/api/members/totp/setup', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'retains the old challenge when the provider credential is invalid' do
      allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(nil)
      provider_switch
      expect(response).to have_http_status(:unauthorized)
      expect(request.session[:totp_pending_member_id]).to eq(member.id.to_s)
      expect(request.session[:totp_pending_expires_at]).to be_present
      expect(cookies[remember_key]).to be_blank
    end
  end

  { missing: 400, invalid: 401, unverified: 401, suspended: 401 }.each do |failure, status|
    it "preserves usable persistence after a #{failure} provider attempt" do
      login
      original = cookies[remember_key]
      payload = { 'sub' => 'replacement', 'email' => member.email, 'email_verified' => failure != :unverified }
      payload = nil if failure == :invalid
      if failure == :suspended
        blocked = create(:member, status: 'suspended')
        payload['email'] = blocked.email
      end
      allow_any_instance_of(FirebaseAuthController).to receive(:verify_firebase_token).and_return(payload)
      post '/api/auth/firebase_login', params: { id_token: failure == :missing ? nil : 'bad-token', rememberMe: true },
        headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(status)
      expect(cookies[remember_key]).to eq(original)
      restore
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(member.email)
    end
  end

  it 'invalidates remembered credentials through the password-change endpoint' do
    login
    put '/api/members/change_password', params: { password: 'changed-password123' },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:no_content)
    restore
    expect(response).to have_http_status(:unauthorized)
  end

  it 'invalidates the old remember cookie when a recovery token resets the password' do
    login
    old_cookie = cookies[remember_key]
    token, encrypted = Devise.token_generator.generate(Member, :reset_password_token)
    member.set(reset_password_token: encrypted, reset_password_sent_at: Time.current)
    put '/api/members/password', params: { member: { resetPasswordToken: token, password: 'reset-password123' } },
      headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:no_content)
    cookies[remember_key] = old_cookie
    restore
    expect(response).to have_http_status(:unauthorized)
  end

  context 'with CSRF protection enabled' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it 'rejects login without CSRF and accepts the current token' do
      login
      expect(response).to have_http_status(:unauthorized)
      expect(cookies[remember_key]).to be_blank
      get '/api/config', headers: { 'User-Agent' => phone }, as: :json
      csrf = URI::DEFAULT_PARSER.unescape(cookies['XSRF-TOKEN'])
      post '/api/members/sign_in', params: { member: { email: member.email, password: password, rememberMe: true } },
        headers: { 'User-Agent' => phone, 'X-XSRF-TOKEN' => csrf }, as: :json
      expect(response).to have_http_status(:ok)
      expect(cookies[remember_key]).to be_present
      expect(cookies['XSRF-TOKEN']).not_to eq(csrf)
    end
  end

  it 'restores after browser restart and renews the cookie for another two weeks' do
    login
    original = cookies[remember_key]
    travel 13.days do
      restore
      expect(response).to have_http_status(:ok)
      expect(cookies[remember_key]).to be_present
      expect(cookies[remember_key]).not_to eq(original)
    end
    travel 15.days do
      restore
      expect(response).to have_http_status(:ok)
    end
  end

  it 'rejects an expired remember cookie' do
    login
    travel 15.days do
      restore
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'does not restore a phone cookie on a desktop' do
    login
    restore(agent: desktop)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'bypasses idle timeout on the phone without changing desktop sessions for the same member' do
    login
    phone_cookie = cookies[remember_key]
    reset!
    login(agent: desktop)
    travel(member.timeout_in + 1.second) do
      # Even a copied remember cookie must not exempt a desktop from timeout.
      cookies[remember_key] = phone_cookie
      get '/api/home', headers: { 'User-Agent' => desktop }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
    # Desktop timeout preserves the existing global logout invalidation policy.
    reset!
    login
    travel(member.timeout_in + 1.second) do
      get '/api/home', headers: { 'User-Agent' => phone }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it 'invalidates a previously issued cookie on logout' do
    login
    token = cookies[remember_key]
    delete '/api/members/sign_out', headers: { 'User-Agent' => phone }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(cookies[remember_key]).to be_blank
    cookies[remember_key] = token
    restore
    expect(response).to have_http_status(:unauthorized)
  end

  [:password, :session_token].each do |attribute|
    it "invalidates remembered credentials when #{attribute} changes" do
      login
      member.reload.update!(attribute => (attribute == :password ? 'new-password123' : SecureRandom.hex))
      restore
      expect(response).to have_http_status(:unauthorized)
    end
  end

  %w[suspended revoked].each do |status|
    it "rejects #{status} members during login and restoration" do
      login
      member.reload.update!(status: status)
      restore
      expect(response).to have_http_status(:unauthorized)
      reset!
      login
      expect(response).to have_http_status(:unauthorized)
      expect(cookies[remember_key]).to be_blank
    end
  end

  [false, true].each do |provider|
    context(provider ? 'provider authentication' : 'password authentication') do
      it 'clears existing persistence after authenticated opt-out' do
        login
        login(provider: provider, remember: false)
        expect(response).to have_http_status(:ok)
        expect(cookies[remember_key]).to be_blank
        restore
        expect(response).to have_http_status(:unauthorized)
      end

      it 'remembers a fully authenticated phone login' do
        login(provider: provider)
        expect(response).to have_http_status(:ok)
        expect(cookies[remember_key]).to be_present
        expect(response.headers['Set-Cookie'].to_s).to include('httponly')
      end

      context 'with TOTP' do
        before { member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(secret)) }

        [true, false].each do |original_choice|
          it "preserves pending persistence #{original_choice} after a failed password retry" do
            login(provider: provider, remember: original_choice)
            expect(response).to have_http_status(:accepted)
            pending = request.session[:mobile_remember_pending]&.deep_dup
            expires_at = request.session[:totp_pending_expires_at]
            post '/api/members/sign_in', params: { member: { email: member.email, password: 'wrong', rememberMe: !original_choice } },
              headers: { 'User-Agent' => phone }, as: :json
            expect(response).to have_http_status(:unauthorized)
            expect(request.session[:mobile_remember_pending]).to eq(pending)
            expect(request.session[:totp_pending_expires_at]).to eq(expires_at)
            expect(cookies[remember_key]).to be_blank
            post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
            expect(response).to have_http_status(:ok)
            expect(cookies[remember_key].present?).to eq(original_choice)
            restore
            expect(response).to have_http_status(original_choice ? :ok : :unauthorized)
          end
        end

        it 'discards the pending opt-in after a successful password retry opts out' do
          login(provider: provider)
          expect(request.session[:mobile_remember_pending]).to be_present
          login(remember: false)
          expect(response).to have_http_status(:accepted)
          expect(request.session[:mobile_remember_pending]).to be_nil
          post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:ok)
          expect(cookies[remember_key]).to be_blank
          restore
          expect(response).to have_http_status(:unauthorized)
        end

        it 'only issues persistence after a valid code and restores without a second challenge' do
          login(provider: provider)
          expect(response).to have_http_status(:accepted)
          expect(cookies[remember_key]).to be_blank
          get '/api/home', headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:unauthorized)
          post '/api/members/totp_sessions', params: { code: 'invalid' }, headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:unprocessable_content)
          expect(cookies[remember_key]).to be_blank
          post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:ok)
          expect(cookies[remember_key]).to be_present
          restore
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).not_to have_key('totp_required')
        end

        it 'cannot restore before completing TOTP' do
          login(provider: provider)
          restore
          expect(response).to have_http_status(:unauthorized)
        end

        it 'expires pending persistence with the challenge' do
          login(provider: provider)
          travel 11.minutes do
            post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
            expect(response).to have_http_status(:unauthorized)
            expect(cookies[remember_key]).to be_blank
          end
        end

        it 'allows cancelling the pending challenge through logout' do
          login(provider: provider)
          delete '/api/members/sign_out', headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:no_content)
          post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:unauthorized)
          expect(cookies[remember_key]).to be_blank
        end

        it 'rechecks member eligibility before issuing persistence' do
          login(provider: provider)
          member.reload.update!(status: 'suspended')
          post '/api/members/totp_sessions', params: { code: ROTP::TOTP.new(secret).now }, headers: { 'User-Agent' => phone }, as: :json
          expect(response).to have_http_status(:unauthorized)
          expect(cookies[remember_key]).to be_blank
        end
      end

      it 'defers persistence until required enrollment is verified' do
        member.update!(role: 'admin')
        allow(SystemConfig).to receive(:enabled?).and_call_original
        allow(SystemConfig).to receive(:enabled?).with('require_totp_admin').and_return(true)
        login(provider: provider)
        expect(response.parsed_body['totp_enrollment_required']).to eq(true)
        expect(cookies[remember_key]).to be_blank
        post '/api/members/totp/setup', headers: { 'User-Agent' => phone }, as: :json
        enrollment_secret = response.parsed_body.fetch('secret')
        post '/api/members/totp/verify', params: { code: ROTP::TOTP.new(enrollment_secret).now }, headers: { 'User-Agent' => phone }, as: :json
        expect(response).to have_http_status(:ok)
        expect(cookies[remember_key]).to be_present
      end
    end
  end
end
