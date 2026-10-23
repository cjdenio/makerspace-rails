require 'rails_helper'

RSpec.describe Slack::CommandsController, type: :controller do
  let(:secret) { 'test-signing-secret' }

  before do
    allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([])
  end

  def sign_request!(body_params)
    body = body_params.to_query
    timestamp = Time.now.to_i.to_s
    signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
    request.headers['X-Slack-Request-Timestamp'] = timestamp
    request.headers['X-Slack-Signature'] = signature
  end

  describe "#verify_slack_signature" do
    context "when SLACK_SIGNING_SECRET is configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
      end

      it "accepts a correctly signed request" do
        sign_request!({ text: 'foo' })
        expect(SlackVolunteerJob).to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(200)
      end

      it "rejects a request with an invalid signature" do
        request.headers['X-Slack-Request-Timestamp'] = Time.now.to_i.to_s
        request.headers['X-Slack-Signature'] = 'v0=bogus'
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end

      it "rejects a stale request" do
        timestamp = (Time.now - 10.minutes).to_i.to_s
        request.headers['X-Slack-Request-Timestamp'] = timestamp
        request.headers['X-Slack-Signature'] = 'v0=irrelevant-staleness-checked-first'
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end
    end

    context "when SLACK_SIGNING_SECRET is not configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(nil)
      end

      it "allows the request through in development" do
        allow(Rails.env).to receive(:development?).and_return(true)
        expect(SlackVolunteerJob).to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(200)
      end

      it "rejects the request outside development" do
        allow(Rails.env).to receive(:development?).and_return(false)
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end
    end
  end

  describe "#checkout" do
    let!(:shop) { create(:shop, slack_channel: "woodshop") }
    let!(:tool) { create(:tool, shop: shop, open: false) }
    let!(:member) { create(:member, :current) }
    let!(:slack_user) { SlackUser.create!(member: member, slack_id: "U123") }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
      allow(Service::ShopSlackChannels).to receive(:associated?).and_return(true)
    end

    it "opens the self-service modal synchronously for an ordinary member's bare command" do
      sign_request!({ text: '', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackConnector).to receive(:open_modal).with("trigger", hash_including(callback_id: "checkout_modal"))

      post :checkout, params: { text: '', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "opens the same menu for an approver's bare command" do
      create(:checkout_approver, member: member, shop_ids: [shop.id.to_s])
      body = { text: "", user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }
      sign_request!(body)
      expect(Service::SlackConnector).to receive(:open_modal).with("trigger", hash_including(callback_id: "checkout_modal"))
      post :checkout, params: body
      expect(response.parsed_body["text"]).to include("Opening checkout menu")
    end

    it "offers an enabled-shop selector outside a shop channel" do
      allow(Service::ShopSlackChannels).to receive(:associated?).and_return(false)
      body = { text: "", user_id: "U123", channel_name: "general", trigger_id: "trigger" }
      sign_request!(body)
      expect(Service::SlackConnector).to receive(:open_modal) do |_trigger, view|
        expect(view[:blocks].map { |block| block[:block_id] }).to include("checkout_shop", "checkout_menu")
        expect(SlackCheckoutModal.decode_metadata(view[:private_metadata])).not_to have_key("shop_id")
      end
      post :checkout, params: body
    end

    %w[revoked suspended inactive nonMember].each do |status|
      it "explains #{status} membership instead of reporting an unlinked account" do
        member.update!(status: status)
        body = { text: "", user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }
        sign_request!(body)
        expect(Service::SlackConnector).not_to receive(:open_modal)
        post :checkout, params: body
        expect(response.parsed_body["text"]).to eq(SlackCheckoutModal.membership_error(member))
        expect(response.parsed_body["text"]).not_to include("Link your Slack")
      end
    end

    it "explains an expired membership" do
      member.update!(expirationTime: 1)
      body = { text: "", user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }
      sign_request!(body)
      expect(Service::SlackConnector).not_to receive(:open_modal)
      post :checkout, params: body
      expect(response.parsed_body["text"]).to include("expired")
    end

    it "admits pending members to the menu even without an expiration date" do
      member.update!(status: "pending", expirationTime: nil)
      body = { text: "", user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }
      sign_request!(body)
      expect(Service::SlackConnector).to receive(:open_modal)
      post :checkout, params: body
    end

    it "opens the modal for an approver who explicitly uses '/checkout request'" do
      create(:checkout_approver, member: member, shop_ids: [shop.id])
      sign_request!({ text: 'request', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: { text: 'request', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "routes a named checkout request to the request job instead of opening the modal" do
      request_params = { text: "request Bandsaw", user_id: "U123", channel_name: "woodshop" }
      sign_request!(request_params)
      expect(SlackCheckoutRequestJob).to receive(:perform_later)
        .with(hash_including("tool_name" => "Bandsaw"))
      expect(Service::SlackConnector).not_to receive(:open_modal)

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch("text")).to include("Processing your request for *Bandsaw*")
    end

    it "defers Slack identity synchronization for a named checkout request" do
      slack_user.destroy
      request_params = {
        text: "request Bandsaw",
        user_id: "UUNLINKED",
        channel_name: "woodshop",
        response_url: "https://example.test/slack-response"
      }
      sign_request!(request_params)
      expect(Service::SlackUserSync).not_to receive(:sync_single)
      expect(SlackCheckoutRequestJob).to receive(:perform_later).with(
        hash_including(
          "tool_name" => "Bandsaw",
          "user_id" => "UUNLINKED",
          "response_url" => "https://example.test/slack-response"
        )
      )

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch("text")).to include("Processing your request for *Bandsaw*")
    end

    it "resolves a checkout request shop from the Slack channel ID" do
      shop.update!(slack_channel: "C12345678")
      request_params = {
        text: "request",
        user_id: "U123",
        channel_name: "woodshop",
        channel_id: "C12345678",
        trigger_id: "trigger"
      }
      sign_request!(request_params)
      expect(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch("text")).to include("Opening checkout request form")
    end

    it "synchronizes an unknown Slack identity before rejecting the command" do
      slack_user.destroy
      sign_request!({ text: '', user_id: "UNEW", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackUserSync).to receive(:sync_single).with("UNEW") do
        SlackUser.create!(member: member, slack_id: "UNEW")
        member
      end
      expect(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: { text: '', user_id: "UNEW", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "lists all open requests when '/checkout request' is used outside a shop channel" do
      tool = create(:tool, name: "Bandsaw")
      ToolCheckoutRequest.create!(member: member, tool: tool, status: "open")
      request_params = { text: "request", channel_name: "general", user_id: "U123" }
      sign_request!(request_params)

      post :checkout, params: request_params

      expect(response.parsed_body.fetch("text")).to include("Bandsaw", tool.shop.name, "open checkout requests")
    end

    it "returns the account-link error for an unlinked request listing" do
      slack_user.destroy
      allow(Service::SlackUserSync).to receive(:sync_single).with("UUNLINKED").and_return(nil)
      request_params = { text: "request", channel_name: "general", user_id: "UUNLINKED" }
      sign_request!(request_params)

      post :checkout, params: request_params

      expect(response.parsed_body.fetch("text")).to include(
        "Link your Slack account to a Member Portal account first"
      )
      expect(response.parsed_body.fetch("text")).not_to include("appropriate shop channel")
    end

    it "suggests volunteering as an approver when the requester has an active checkout in the shop" do
      create(:tool_checkout, member: member, tool: create(:tool, shop: shop))
      create(:tool, shop: shop)
      request_params = { text: "request", channel_name: "woodshop", user_id: "U123", trigger_id: "trigger" }
      sign_request!(request_params)
      allow(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: request_params

      expect(response.parsed_body.fetch("text")).to include("Volunteering as a checkout approver")
    end

    it "routes '/checkout active' to SlackCheckoutActiveJob" do
      sign_request!({ text: "active" })
      expect(SlackCheckoutActiveJob).to receive(:perform_later).with(hash_including("text" => "active"))

      post :checkout, params: { text: "active" }
      expect(response).to have_http_status(200)
    end

    it "shows textual approval help only when the caller currently has authority" do
      approver = create(:checkout_approver, member: member, tool_ids: [tool.id.to_s])

      body = { text: "help", user_id: "U123" }
      sign_request!(body)
      post :checkout, params: body
      expect(response.parsed_body.fetch("text")).to include("/checkout @member tool")

      member.update!(member_contract_signed_date: nil, resource_manager_shop_ids: [shop.id.to_s])
      sign_request!(body)
      post :checkout, params: body
      expect(response.parsed_body.fetch("text")).not_to include("/checkout @member tool")

      approver.destroy!
      member.update!(role: "resource_manager", resource_manager_shop_ids: [])
      sign_request!(body)
      post :checkout, params: body
      expect(response.parsed_body.fetch("text")).not_to include("/checkout @member tool")
    end

    it "asks an unidentified caller to link their account" do
      sign_request!({ text: "" })
      post :checkout, params: { text: "" }
      expect(response.parsed_body.fetch("text")).to include("Link your Slack account")
    end

    it "opens textual group approval synchronously using the command trigger" do
      member.update!(role: 'admin')
      target = create(:member, :current)
      SlackUser.create!(member: target, slack_id: 'UTARGET', name: 'target')
      group = ToolGroup.create!(shop: shop, name: 'Starter kit', included_tool_ids: [tool.id.to_s])
      body = { text: '<@UTARGET> Starter kit', user_id: 'U123', channel_name: 'woodshop', trigger_id: 'fresh-trigger' }
      sign_request!(body)
      expect(SlackCheckoutJob).not_to receive(:perform_later)
      expect(Service::SlackUserSync).not_to receive(:sync_single)
      expect(Service::SlackConnector).to receive(:open_modal).with('fresh-trigger', hash_including(callback_id: 'group_checkout_approve'))
      post :checkout, params: body
      expect(response.parsed_body.fetch('text')).to include('Review the group checkout')
      expect(ToolCheckout.where(member_id: target.id)).not_to exist
    end

    it "rejects unauthorized group commands without opening a modal or queuing a job" do
      group = ToolGroup.create!(shop: shop, name: 'Starter kit', included_tool_ids: [tool.id.to_s])
      body = { text: "#{member.email} #{group.name}", user_id: 'U123', channel_name: 'woodshop', trigger_id: 'fresh-trigger' }
      sign_request!(body)
      expect(SlackCheckoutJob).not_to receive(:perform_later)
      expect(Service::SlackConnector).not_to receive(:open_modal)
      post :checkout, params: body
      expect(response.parsed_body.fetch('text')).not_to include('Review the group checkout')
    end

    it "offers email recovery for an unlinked group target without synchronizing Slack" do
      member.update!(role: 'admin')
      group = ToolGroup.create!(shop: shop, name: 'Starter kit', included_tool_ids: [tool.id.to_s])
      body = { text: "<@UNKNOWN> #{group.name}", user_id: 'U123', channel_name: 'woodshop', trigger_id: 'fresh-trigger' }
      sign_request!(body)
      expect(Service::SlackUserSync).not_to receive(:sync_single)
      expect(SlackCheckoutJob).not_to receive(:perform_later)
      expect(Service::SlackConnector).not_to receive(:open_modal)
      post :checkout, params: body
      expect(response.parsed_body.fetch('text')).to include('Member Portal email')
    end

    it "still routes a plain '/checkout @member tool' to SlackCheckoutJob" do
      sign_request!({ text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" })
      expect(SlackCheckoutJob).to receive(:perform_later)
      expect(SlackCheckoutRequestJob).not_to receive(:perform_later)

      post :checkout, params: { text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" }

      expect(response).to have_http_status(200)
    end

    it "passes the Slack channel ID through to normal checkout processing" do
      shop.update!(slack_channel: "C12345678")
      request_params = {
        text: "#{member.email} Bandsaw",
        user_id: "U123",
        channel_name: "woodshop",
        channel_id: "C12345678"
      }
      sign_request!(request_params)
      expect(SlackCheckoutJob).to receive(:perform_later).with(
        hash_including("channel_id" => "C12345678")
      )

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
    end

    context "outside a configured shop channel" do
      let(:wood_shop) { create(:shop, name: "Wood Shop") }
      let(:metal_shop) { create(:shop, name: "Metal Shop") }
      let(:channels) do
        [
          Service::ShopSlackChannels::Channel.new(shop: wood_shop, id: "C12345678", name: "#wood-shop"),
          Service::ShopSlackChannels::Channel.new(shop: metal_shop, id: "C23456789", name: "#metal-shop")
        ]
      end

      before do
        allow(Service::ShopSlackChannels).to receive(:associated?).and_return(false)
        allow(Service::ShopSlackChannels).to receive(:resolved).and_return(channels)
      end

      ["request", "request Bandsaw", "@someone Bandsaw"].each do |command_text|
        it "directs '#{command_text.presence || 'bare /checkout'}' to the public shop channels" do
          sign_request!(text: command_text, channel_name: "general")

          post :checkout, params: { text: command_text, channel_name: "general" }

          payload = response.parsed_body
          expect(payload["response_type"]).to eq("ephemeral")
          expect(payload["text"]).to include(
            "appropriate shop channel",
            "<#C12345678> — *Wood Shop*",
            "<#C23456789> — *Metal Shop*",
            "Join the appropriate channel",
            "`/checkout` there"
          )
          expect(SlackCheckoutJob).not_to have_been_enqueued
          expect(SlackCheckoutRequestJob).not_to have_been_enqueued
        end
      end

      it "uses generic instructions when no public channels can be resolved" do
        allow(Service::ShopSlackChannels).to receive(:resolved).and_return([])
        sign_request!(text: "request", channel_name: "general")

        post :checkout, params: { text: "request", channel_name: "general" }

        expect(response.parsed_body["text"]).to include(
          "appropriate shop channel",
          "join the public Slack channel",
          "run `/checkout` there"
        )
      end

      it "uses generic instructions when channel inventory is unavailable" do
        allow(Service::ShopSlackChannels).to receive(:resolved).and_raise(Redis::CannotConnectError)
        sign_request!(text: "@someone Bandsaw", channel_name: "general")

        expect do
          post :checkout, params: { text: "@someone Bandsaw", channel_name: "general" }
        end.not_to raise_error

        expect(response.parsed_body["text"]).to include("join the public Slack channel")
      end
    end
  end

  describe "#reserve" do
    let!(:shop) { create(:shop, slack_channel: "woodshop", reservable: true) }
    let!(:member) { create(:member, :current) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(secret)
      SlackUser.create!(member: member, slack_id: "U123")
    end

    it "retains the response URL and initiating user in modal metadata" do
      command = {
        channel_name: "woodshop", user_id: "U123", trigger_id: "trigger",
        response_url: "https://hooks.slack.test/responses/secret"
      }
      sign_request!(command)
      expect(Service::SlackConnector).to receive(:open_modal) do |trigger_id, view|
        metadata = JSON.parse(view.fetch(:private_metadata))
        expect(trigger_id).to eq("trigger")
        expect(view[:notify_on_close]).to be(true)
        expect(metadata).to include(
          "response_url" => command[:response_url], "slack_user_id" => "U123",
          "shop_id" => shop.id.to_s, "member_id" => member.id.to_s
        )
      end

      post :reserve, params: command

      expect(response).to have_http_status(:ok)
    end

    it "only exposes enabled reservable tools whose checkout requirements are met" do
      eligible = create(:tool, shop: shop, name: "Open Tool", open: true)
      create(:tool, shop: shop, name: "Checkout Required", open: false)
      create(:tool, shop: shop, name: "Disabled Tool", open: true, disabled: true)
      create(:tool, shop: shop, name: "Not Reservable", open: true, reservable: false)
      command = { channel_name: "woodshop", user_id: "U123", trigger_id: "trigger" }
      sign_request!(command)
      expect(Service::SlackConnector).to receive(:open_modal) do |_trigger_id, view|
        tools_block = view[:blocks].find { |block| block[:block_id] == "tools" }
        expect(tools_block.dig(:element, :options)).to contain_exactly(
          hash_including(value: eligible.id.to_s)
        )
      end

      post :reserve, params: command

      expect(response).to have_http_status(:ok)
    end
  end
end
