require 'rails_helper'

RSpec.describe RegistrationsController, type: :controller do
  set_devise_mapping

  email = 'new_emails@email.com'
  let(:token) {SecureRandom.urlsafe_base64(nil, false)}
  let(:encrypted_token) {BCrypt::Password.create(token)}
  let(:token_model) { create(:registration_token, email: email)}

  let(:valid_attributes) {
    {
      firstname: 'New',
      lastname: 'Member',
      email: email,
      password: 'password',
      password_confirmation: 'password',
      token_id: token_model.id,
      token: token,
      signature: "data:image/png;base64," + Base64.encode64(File.new("#{Rails.root}/spec/support/makerspace.png").read)
    }
  }

  let(:invalid_attributes) {
    skip("Add a hash of attributes invalid for your model")
  }

  before(:all) do
    clear_email
  end

  before(:each) do
    token_model.update(token: encrypted_token)
  end

  around do |example|
    previous_secret = ENV['TURNSTILE_SECRET']
    ENV.delete('TURNSTILE_SECRET')
    example.run
  ensure
    if previous_secret.nil?
      ENV.delete('TURNSTILE_SECRET')
    else
      ENV['TURNSTILE_SECRET'] = previous_secret
    end
  end

  describe "GET #status" do
    after { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, "false") }

    it "reports locked: false by default" do
      get :status, format: :json
      expect(response).to have_http_status(200)
      expect(JSON.parse(response.body)).to eq("locked" => false)
    end

    it "reports locked: true when the signup lockout flag is enabled" do
      SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, "true")
      get :status, format: :json
      expect(JSON.parse(response.body)).to eq("locked" => true)
    end
  end

  describe "signup lockout" do
    after { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, "false") }

    before { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, "true") }

    it "blocks POST #create without creating a member" do
      expect {
        post :create, params: valid_attributes, format: :json
      }.not_to change(Member, :count)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq(
        'status' => 403,
        'error' => 'forbidden',
        'message' => 'Signups are currently disabled for maintenance.'
      )
    end

    it "blocks GET #new without sending a welcome email" do
      expect(MemberMailer).not_to receive(:welcome_email)
      get :new, params: { email: "foo@foo.com" }, format: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST #create" do
    context "when Turnstile is configured" do
      let(:verifier) { instance_double(Service::TurnstileVerifier) }

      before do
        ENV['TURNSTILE_SECRET'] = 'test-secret'
      end

      it "creates the member after a successful verification" do
        expect(Service::TurnstileVerifier).to receive(:new).with(
          token: 'browser-token',
          remote_ip: anything
        ).and_return(verifier)
        allow(verifier).to receive(:valid?).and_return(true)

        expect {
          post :create,
            params: valid_attributes.merge('cf-turnstile-response' => 'browser-token'),
            format: :json
        }.to change(Member, :count).by(1)
      end

      it "uses the canonical Turnstile response when an underscored parameter is also present" do
        expect(Service::TurnstileVerifier).to receive(:new).with(
          token: 'canonical-token',
          remote_ip: anything
        ).and_return(verifier)
        allow(verifier).to receive(:valid?).and_return(true)

        expect {
          post :create,
            params: valid_attributes.merge(
              'cf_turnstile_response' => 'noncanonical-token',
              'cf-turnstile-response' => 'canonical-token'
            ),
            format: :json
        }.to change(Member, :count).by(1)
      end

      it "returns forbidden without creating a member after a failed verification" do
        allow(Service::TurnstileVerifier).to receive(:new).and_return(verifier)
        allow(verifier).to receive(:valid?).and_return(false)

        expect {
          post :create,
            params: valid_attributes.merge('cf-turnstile-response' => 'invalid-token'),
            format: :json
        }.not_to change(Member, :count)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)).to eq(
          'status' => 403,
          'error' => 'forbidden',
          'message' => 'Turnstile verification failed'
        )
      end
    end

    context "with valid params" do
      it "creates a new Member" do
        expect {
          post :create, params: valid_attributes, format: :json
        }.to change(Member, :count).by(1)
      end

      it "assigns a newly created member as @member" do
        post :create, params: valid_attributes, format: :json
        expect(Member.last).to be_a(Member)
        expect(Member.last).to be_persisted
      end

      it "marks a newly registered member as pending until a card is issued" do
        post :create, params: valid_attributes, format: :json

        expect(Member.last.status).to eq('pending')
      end

      it "renders json of the created member" do
        post :create, params: valid_attributes, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        expect(parsed_response['id']).to eq(Member.last.id.as_json)
      end

      it "sends registration notification to us" do
        allow(MemberMailer).to receive_message_chain(:member_registered, :deliver_later)
        expect(MemberMailer).to receive_message_chain(:member_registered, :deliver_later)
        post :create, params: valid_attributes, format: :json
      end

      it "continues signup and reports a Slack invite failure without returning 500" do
        slack_error = StandardError.new("not_authed")
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SLACK_INVITES_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_ADMIN_TOKEN").and_return("admin-token")
        allow(::Service::SlackConnector).to receive(:invite_to_slack).and_raise(slack_error)
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_return(true)
        allow(Honeybadger).to receive(:notify)

        expect do
          post :create, params: valid_attributes, format: :json
        end.to change(Member, :count).by(1)

        expect(response).to have_http_status(200)

        audit_entry = AuditLog.where(event_type: "slack_manual_invite_required").last
        expect(audit_entry).to be_present
        expect(audit_entry.resource_id).to eq(Member.last.id)
        expect(audit_entry.slack_channel).to eq(::Service::SlackConnector.admin_channel)
        expect(audit_entry.slack_posted).to be(true)

        expect(::Service::SlackConnector).to have_received(:send_slack_message).with(
          /Manual Slack invite required.*not_authed/i,
          ::Service::SlackConnector.admin_channel
        )
        expect(Honeybadger).to have_received(:notify).with(
          slack_error,
          context: hash_including(
            member_email: email
          )
        )
      end

      it "continues signup when posting the invite failure to Slack also fails" do
        invite_error = StandardError.new("not_authed")
        log_error = StandardError.new("interface log not_authed")
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SLACK_INVITES_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_ADMIN_TOKEN").and_return("admin-token")
        allow(::Service::SlackConnector).to receive(:invite_to_slack).and_raise(invite_error)
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_raise(log_error)
        allow(Honeybadger).to receive(:notify)

        post :create, params: valid_attributes, format: :json

        expect(response).to have_http_status(200)
        audit_entry = AuditLog.where(event_type: "slack_manual_invite_required").last
        expect(audit_entry).to be_present
        expect(audit_entry.slack_channel).to eq(::Service::SlackConnector.admin_channel)
        expect(audit_entry.slack_posted).to be(false)
        expect(Honeybadger).to have_received(:notify).with(
          invite_error,
          context: hash_including(manual_action: "invite")
        )
        expect(Honeybadger).to have_received(:notify).with(
          log_error,
          context: hash_including(slack_channel: ::Service::SlackConnector.admin_channel)
        )
      end
    end

    # context "with invalid params" do
    #   it "assigns a newly created but unsaved registration as @registration" do
    #     post :create, params: {registration: invalid_attributes}, session: valid_session
    #     expect(assigns(:registration)).to be_a_new(Registration)
    #   end
    #
    #   it "re-renders the 'new' template" do
    #     post :create, params: {registration: invalid_attributes}, session: valid_session
    #     expect(response).to render_template("new")
    #   end
    # end
  end

  describe "GET #new" do
    it "throws errors if email missing" do
      get :new, format: :json
      expect(response).to have_http_status(422)
    end

    it "it notifies admin and raises error if email already exists" do
      create(:member, email: "foo@foo.com")
      get :new, params: {email: "foo@foo.com"}, format: :json
      expect(response).to have_http_status(409)
    end

    it "sends welcome email to new member" do
      allow(MemberMailer).to receive_message_chain(:welcome_email, :deliver_later)
      expect(MemberMailer).to receive_message_chain(:welcome_email, :deliver_later)
      expect(MemberMailer).to receive(:welcome_email).with("foo@foo.com")
      get :new, params: {email: "foo@foo.com"}, format: :json
    end
  end
end
