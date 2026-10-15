require 'rails_helper'

RSpec.describe Admin::SystemConfigsController, type: :controller do
  set_devise_mapping

  let(:admin)  { create(:member, role: 'admin') }
  let(:member) { create(:member) }

  before do
    allow(Service::SlackChannelCache).to receive(:status).and_return(
      available: true,
      total_channels: 42,
      last_updated_at: "2026-07-28T12:00:00Z"
    )
  end

  describe "GET #index — devise_timeout_minutes" do
    before { sign_in admin }

    it "defaults to '30' when devise_timeout_minutes has not been configured" do
      get :index, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['security']['devise_timeout_minutes']).to eq('30')
    end

    it "reflects the configured value once set" do
      SystemConfig.set('devise_timeout_minutes', '45')

      get :index, format: :json

      parsed_response = JSON.parse(response.body)
      expect(parsed_response['security']['devise_timeout_minutes']).to eq('45')
    end
  end

  describe "signup_lockout_enabled" do
    before { sign_in admin }
    after { SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, "false") }

    it "defaults to false and can be toggled via update_flag" do
      get :index, format: :json
      expect(JSON.parse(response.body).dig("flags", "signup_lockout_enabled")).to eq(false)

      put :update_flag,
          params: { key: SystemConfig::SIGNUP_LOCKOUT_ENABLED, value: "true" },
          format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.enabled?(SystemConfig::SIGNUP_LOCKOUT_ENABLED)).to be(true)

      get :index, format: :json
      expect(JSON.parse(response.body).dig("flags", "signup_lockout_enabled")).to eq(true)
    end
  end

  describe "reservation_token" do
    before { sign_in admin }

    it "returns an empty default and persists the editable token setting" do
      get :index, format: :json
      expect(JSON.parse(response.body).dig("reservation", "reservation_token")).to eq("")

      put :update_setting,
          params: { key: "reservation_token", value: "agenda-secret" },
          format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.get("reservation_token")).to eq("agenda-secret")
    end
  end

  describe "Slack channel settings" do
    before do
      sign_in admin
      allow(Service::SlackChannelCache).to receive(:lookup)
    end

    it "defaults resource managers and members relations to their separate channels" do
      get :index, format: :json
      channels = JSON.parse(response.body).fetch("slack")
      expect(channels).to include("slack_channel_rm" => "resource_managers",
        "slack_channel_admin" => "members_relations")
    end

    it "returns the configured resource managers and members relations channels independently" do
      SystemConfig.set("slack_channel_rm", "CRESOURCE")
      SystemConfig.set("slack_channel_admin", "CMEMBERS")
      get :index, format: :json
      channels = JSON.parse(response.body).fetch("slack")
      expect(channels).to include("slack_channel_rm" => "CRESOURCE", "slack_channel_admin" => "CMEMBERS")
    end

    it "returns Slack channel cache status and its tracked job" do
      get :index, format: :json

      body = JSON.parse(response.body)
      expect(body.dig("slack", "channel_cache")).to include(
        "available" => true,
        "total_channels" => 42,
        "last_updated_at" => "2026-07-28T12:00:00Z"
      )
      expect(body["jobs"]).to include(
        include(
          "key" => "slack_channel_cache",
          "task" => "slack:refresh_public_channel_cache"
        )
      )
    end

    it "normalizes leading hashes and checks the public-channel cache" do
      put :update_setting,
          params: { key: "slack_channel_logs", value: "##portal-logs" },
          format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.get("slack_channel_logs")).to eq("#portal-logs")
      expect(Service::SlackChannelCache).to have_received(:lookup).with(
        "#portal-logs",
        refresh_on_miss: false
      )
    end

    it "defaults the new-members channel to new_members and allows it to be updated" do
      get :index, format: :json
      expect(JSON.parse(response.body).dig("slack", "slack_channel_new_members")).to eq("new_members")

      put :update_setting,
          params: { key: "slack_channel_new_members", value: "#new-members-2" },
          format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.get("slack_channel_new_members")).to eq("#new-members-2")
    end
  end

  describe "PUT #update_setting — devise_timeout_minutes" do
    before { sign_in admin }

    it "accepts and persists a valid positive integer" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '15' }, format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('15')
    end

    it "rejects zero" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '0' }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(422)
      expect(parsed_response['error']).to eq('devise_timeout_minutes must be a positive whole number of minutes')
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a negative number" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '-5' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a non-integer decimal value" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '5.5' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a non-numeric value" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: 'not-a-number' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "does not overwrite a previously valid value with a rejected update" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '20' }, format: :json
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('20')

      put :update_setting, params: { key: 'devise_timeout_minutes', value: '0' }, format: :json
      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('20')
    end
  end

  describe "authorization" do
    it "forbids a regular member from viewing system configs" do
      sign_in member
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it "forbids a regular member from updating devise_timeout_minutes" do
      sign_in member
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '15' }, format: :json
      expect(response).to have_http_status(403)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end
  end

  describe "POST #run_job" do
    before do
      sign_in admin
      allow(ReservationSlackCanvasRebuildJob).to receive(:perform_later)
      allow(SlackChannelCacheRefreshJob).to receive(:perform_later)
    end

    it "enqueues the reservation canvas rake job" do
      post :run_job,
           params: { key: "reservation_canvas_rebuild" },
           format: :json

      expect(response).to have_http_status(200)
      expect(ReservationSlackCanvasRebuildJob).to have_received(:perform_later)
    end

    it "enqueues the Slack channel cache rebuild job" do
      post :run_job,
           params: { key: "slack_channel_cache" },
           format: :json

      expect(response).to have_http_status(200)
      expect(SlackChannelCacheRefreshJob).to have_received(:perform_later)
    end

    it "enqueues the card expiration check job" do
      allow(CardExpirationCheckJob).to receive(:perform_later)

      post :run_job,
           params: { key: "card_expiration_check" },
           format: :json

      expect(response).to have_http_status(200)
      expect(CardExpirationCheckJob).to have_received(:perform_later)
    end

    it "enqueues the checkout request digest job" do
      allow(CheckoutRequestDigestJob).to receive(:perform_later)

      post :run_job,
           params: { key: "checkout_request_digest" },
           format: :json

      expect(response).to have_http_status(200)
      expect(CheckoutRequestDigestJob).to have_received(:perform_later)
    end

    it "enqueues the checkout request reminder job" do
      allow(CheckoutRequestReminderJob).to receive(:perform_later)

      post :run_job,
           params: { key: "checkout_request_reminder" },
           format: :json

      expect(response).to have_http_status(200)
      expect(CheckoutRequestReminderJob).to have_received(:perform_later)
    end

    it "enqueues the membership expiration notice job" do
      allow(MembershipExpirationNoticeJob).to receive(:perform_later)

      post :run_job,
           params: { key: "membership_expiration_notice" },
           format: :json

      expect(response).to have_http_status(200)
      expect(MembershipExpirationNoticeJob).to have_received(:perform_later)
    end
  end
end
