require 'swagger_helper'

describe 'Registrations API', type: :request do
  let(:auth_member) { create(:member) }

  path '/members/sign_in' do
    post 'Signs in user' do
      tags 'Authentication'
      operationId 'signIn'
      consumes 'application/json'
      produces 'application/json'
      description 'Optional rememberMe enables a two-week renewable remember cookie only on iPhone or Android phone clients, after required TOTP completion. Omission is false. Empty bodies restore existing sessions. Nonempty member payloads require fresh valid credentials, even with an existing session. Successful fresh authentication replaces any previous TOTP challenge with the authenticated account\'s requirements. Failed retries preserve the original pending persistence choice and expiry; successful replacement authentication applies its own choice.'
      parameter name: :'User-Agent', in: :header, required: false, schema: { type: :string }
      parameter name: :signInDetails, in: :body, schema: {
        title: :signInDetails,
        type: :object,
        properties: {
          member: {
            type: :object,
            properties: {
              email: { type: :string },
              password: { type: :string },
              rememberMe: { type: :boolean, default: false }
            }
          }
        }
      }, required: true

      response '200', 'User signed in' do
        schema '$ref' => '#/components/schemas/Member'
        let(:signInDetails) { { member: { email: auth_member.email, password: 'password' } } }
        run_test!

        context 'phone opts in' do
          let(:'User-Agent') { 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148' }
          let(:signInDetails) { { member: { email: auth_member.email, password: 'password', rememberMe: true } } }
          run_test! { expect(cookies['remember_member_token']).to be_present }
        end

        context 'replacing another account with a pending TOTP challenge' do
          before do
            pending_member = create(:member, otp_required_for_login: true,
              otp_secret_encrypted: TotpService.encrypt(TotpService.generate_secret))
            post '/api/members/sign_in', params: { member: { email: pending_member.email, password: 'password' } }, as: :json
            expect(response).to have_http_status(:accepted)
          end
          run_test! do
            expect(request.session[:totp_pending_member_id]).to be_nil
            expect(request.session[:totp_pending_expires_at]).to be_nil
          end
        end
      end

      response '202', 'TOTP challenge required; no remember cookie issued yet' do
        schema type: :object, required: ['totp_required'], properties: { totp_required: { type: :boolean } }
        let(:'User-Agent') { 'Mozilla/5.0 (iPhone) Mobile/15E148' }
        let(:signInDetails) { { member: { email: auth_member.email, password: 'password', rememberMe: true } } }
        before { auth_member.update!(otp_required_for_login: true, otp_secret_encrypted: TotpService.encrypt(TotpService.generate_secret)) }
        run_test! { expect(cookies['remember_member_token']).to be_blank }
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:signInDetails) { { member: { email: auth_member.email, password: 'wrong password' } } }
        run_test!

        context 'with an existing ordinary session requesting persistence' do
          before { sign_in auth_member }
          let(:'User-Agent') { 'Mozilla/5.0 (iPhone) Mobile/15E148' }
          let(:signInDetails) { { member: { email: auth_member.email, password: 'wrong password', rememberMe: true } } }
          run_test! { expect(cookies['remember_member_token']).to be_blank }
        end
      end
    end
  end

  path '/members/sign_out' do
    delete 'Signs out user' do
      tags 'Authentication'
      operationId 'signOut'

      response '204', 'User signed out' do
        before { sign_in create(:member) }
        run_test!
      end
    end
  end

  path '/members/password' do
    post 'Sends password reset instructions' do
      tags 'Password'
      operationId 'requestPasswordReset'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :passwordResetDetails, in: :body, schema: {
        title: :passwordResetDetails,
        type: :object,
        properties: {
          member: {
            type: :object,
            properties: {
              email: { type: :string }
            }
          }
        }
      }, required: true

      response '201', 'Instructions sent' do
        before { auth_member }
        let(:passwordResetDetails) { { member: { email: auth_member.email } } }
        run_test!
      end

      response '422', 'Email not found' do
        schema '$ref' => '#/components/schemas/passwordError'
        let(:passwordResetDetails) { { member: { email: 'not-a-member@example.com' } } }
        run_test!
      end
    end

    put 'Updates member password' do
      tags 'Password'
      operationId 'resetPassword'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :passwordResetDetails, in: :body, schema: {
        title: :passwordResetDetails,
        type: :object,
        properties: {
          member: {
            type: :object,
            properties: {
              resetPasswordToken: { type: :string },
              password: { type: :string }
            }
          }
        }
      }, required: true

      response '204', 'Password reset' do
        let(:raw_token) do
          token, hashed_token = Devise.token_generator.generate(Member, :reset_password_token)
          auth_member.update!(
            reset_password_token: hashed_token,
            reset_password_sent_at: Time.now.utc
          )
          token
        end
        let(:passwordResetDetails) do
          { member: { resetPasswordToken: raw_token, password: 'password' } }
        end
        run_test!
      end

      response '422', 'Invalid token' do
        schema '$ref' => '#/components/schemas/passwordResetError'
        let(:passwordResetDetails) do
          { member: { resetPasswordToken: 'invalid-token', password: 'password' } }
        end
        run_test!
      end
    end
  end

  path '/members' do
    post 'Registers new member' do
      tags 'Authentication'
      operationId 'registerMember'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :registerMemberDetails, in: :body, schema: {
        title: :registerMemberDetails,
        type: :object,
        properties: {
          email: { type: :string },
          password: { type: :string },
          firstname: { type: :string },
          lastname: { type: :string },
          phone: { type: :string },
          'cf-turnstile-response': {
            type: :string,
            description: 'Cloudflare Turnstile token; enforced when TURNSTILE_SECRET is configured'
          },
          address: {
            type: :object,
            properties: {
              street: { type: :string },
              unit: { type: :string },
              city: { type: :string },
              state: { type: :string },
              postalCode: { type: :string }
            }
          }
        },
        required: [:email, :password, :firstname, :lastname]
      }, required: true

      response '200', 'Member registered' do
        schema '$ref' => '#/components/schemas/Member'
        let(:registerMemberDetails) do
          { firstname: 'First', lastname: 'Last', email: 'first@last.com', password: 'password' }
        end
        run_test!
      end

      response '422', 'Email already exists' do
        before { create(:member, email: 'existing@example.com') }
        schema '$ref' => '#/components/schemas/error'
        let(:registerMemberDetails) do
          {
            firstname: 'First',
            lastname: 'Last',
            email: 'existing@example.com',
            password: 'password'
          }
        end
        run_test!
      end

      response '403', 'Signups locked for maintenance' do
        before { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, 'true') }
        after { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, 'false') }
        schema '$ref' => '#/components/schemas/error'
        let(:registerMemberDetails) do
          { firstname: 'First', lastname: 'Last', email: 'first@last.com', password: 'password' }
        end
        run_test!
      end
    end
  end

  path '/signup_status' do
    get 'Checks whether new signups are locked for maintenance' do
      tags 'Authentication'
      operationId 'getSignupStatus'
      produces 'application/json'

      response '200', 'Signup status returned' do
        schema type: :object, properties: { locked: { type: :boolean } }, required: [:locked]
        run_test!
      end
    end
  end

  path '/send_registration' do
    post 'Sends registration email' do
      tags 'Authentication'
      operationId 'sendRegistrationEmail'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :registrationEmailDetails, in: :body, schema: {
        title: :registrationEmailDetails,
        type: :object,
        properties: {
          email: { type: :string }
        },
        required: [:email]
      }, required: true

      response '204', 'Registration email sent' do
        let(:registrationEmailDetails) { { email: 'first@last.com' } }
        run_test!
      end

      response '409', 'Email already exists' do
        before { create(:member, email: 'existing@example.com') }
        schema '$ref' => '#/components/schemas/error'
        let(:registrationEmailDetails) { { email: 'existing@example.com' } }
        run_test!
      end
    end
  end
end
