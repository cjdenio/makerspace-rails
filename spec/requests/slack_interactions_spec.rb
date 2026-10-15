require "rails_helper"

RSpec.describe "Slack interactions", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(nil)
    allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([])
  end

  it "rejects unsigned requests when the signing secret is absent" do
    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to include(
      "error" => "Slack signing secret is not configured"
    )
  end

  it "allows the missing-secret bypass in development" do
    allow(Rails.env).to receive(:development?).and_return(true)

    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:ok)
  end

  context "with a checkout request submission" do
    let(:shop) { create(:shop) }
    let(:tool) { create(:tool, shop: shop, open: false) }
    let(:member) { create(:member, :current) }

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      SlackUser.create!(member: member, slack_id: "USUBMITTER")
      allow(Service::SlackConnector).to receive(:send_slack_message)
      allow(REDIS).to receive(:set).and_return(true)
      allow(REDIS).to receive(:eval).and_return(1)
    end

    def submit(tool_id: tool.id.to_s, shop_id: shop.id.to_s, user_id: "USUBMITTER", note: nil)
      payload = {
        type: "view_submission", user: { id: user_id },
        view: {
          callback_id: "checkout_request_submit",
          private_metadata: { shop_id: shop_id }.to_json,
          state: { values: {
            tool: { tool: { selected_option: { value: tool_id } } },
            note: { note: { value: note } }
          } }
        }
      }
      post "/slack/interactions", params: { payload: payload.to_json }
    end

    it "creates a request and queues its announcement and confirmation" do
      expect_any_instance_of(ToolCheckoutRequest).not_to receive(:announce_request)
      submit(note: "Please show me the blade guard")

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(ToolCheckoutRequest.last).to have_attributes(member_id: member.id, tool_id: tool.id, note: "Please show me the blade guard")
      expect(CheckoutNotificationJob).to have_been_enqueued.with("request", ToolCheckoutRequest.last.id.to_s)
      expect(SlackCheckoutOutcomeJob).to have_been_enqueued.with(include("unpaid volunteers"), kind_of(String), "USUBMITTER")
    end

    it "queues group request notifications before clearing the legacy modal" do
      group = ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s], requestable: true)
      expect_any_instance_of(ToolCheckoutRequest).not_to receive(:announce_request)
      expect_any_instance_of(ToolCheckoutRequest).not_to receive(:notify_requestor)
      submit(tool_id: "group:#{group.id}")
      expect(response.parsed_body).to eq('response_action' => 'clear')
      expect(ToolCheckoutRequest.last.tool_group_id).to eq(group.id)
      expect(CheckoutNotificationJob).to have_been_enqueued.with('request', ToolCheckoutRequest.last.id.to_s)
    end

    it "uses the submitting Slack identity instead of trusting metadata" do
      attacker = create(:member, :current)
      SlackUser.create!(member: attacker, slack_id: "UATTACKER")
      submit(user_id: "UATTACKER")

      expect(ToolCheckoutRequest.last.member_id).to eq(attacker.id)
    end

    it "clears the legacy modal when outcome enqueueing fails after creation" do
      allow(SlackCheckoutOutcomeJob).to receive(:enqueue).and_raise(StandardError, "secret response URL")
      allow(Service::ErrorReporter).to receive(:notify)
      submit
      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: "open")).to exist
      expect(Service::ErrorReporter).to have_received(:notify).with("Slack checkout outcome enqueue failed", context: hash_including(phase: "enqueue"))
    end

    it "rejects a tool tampered to belong to another shop" do
      other_tool = create(:tool, open: false)
      submit(tool_id: other_tool.id.to_s)

      expect(response.parsed_body).to include("response_action" => "errors")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "returns a field error for duplicate submissions" do
      ToolCheckoutRequest.create!(member: member, tool: tool)
      submit

      expect(response.parsed_body.dig("errors", "tool")).to eq("An open request already exists for this tool")
    end

    it "rejects unmet prerequisites using the shared checkout policy" do
      prerequisite = create(:tool, shop: shop)
      tool.update!(prerequisite_ids: [prerequisite.id.to_s])
      submit

      expect(response.parsed_body.dig("errors", "tool")).to include("prerequisite checkouts")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "rejects a revoked checkout record using the shared checkout policy" do
      create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)
      submit

      expect(response.parsed_body.dig("errors", "tool")).to eq("A checkout record already exists for this tool")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "returns the model's note validation as a Block Kit field error" do
      submit(note: "x" * 129)

      expect(response.parsed_body.dig("errors", "note")).to include("too long")
      expect(ToolCheckoutRequest.count).to eq(0)
    end
  end

  context "with the checkout modal workflow" do
    let(:member) { create(:member, :current) }
    let(:shop) { create(:shop, name: "Woodshop") }
    let(:tool) { create(:tool, shop: shop, name: "Bandsaw") }
    let(:response_url) { "https://hooks.slack.test/commands/original" }

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      SlackUser.create!(member: member, slack_id: "UMODAL")
      allow(REDIS).to receive(:set).and_return(true)
      allow(REDIS).to receive(:eval).and_return(1)
      allow(Service::ErrorReporter).to receive(:notify)
      allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
      allow_any_instance_of(ToolCheckoutRequest).to receive(:remove_announcement)
      allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
      allow_any_instance_of(ToolCheckout).to receive(:announce_checkout_success)
      allow(Service::SlackConnector).to receive(:open_modal)
      allow(Service::SlackConnector).to receive(:update_modal) do |_id, view, **_options|
        @updated = view.deep_stringify_keys
      end
    end

    def start_modal(selected_shop: shop)
      @view = SlackCheckoutModal.entry(member: member, shop: selected_shop,
        slack_user_id: "UMODAL", response_url: response_url).deep_stringify_keys
    end

    def modal_metadata
      SlackCheckoutModal.decode_metadata(@view.fetch("private_metadata"))
    end

    def modal_step
      modal_metadata.fetch("step")
    end

    def interact(action: nil, value: nil, block: nil, note: nil, reason: nil, user_id: "UMODAL", display: "FORGED DISPLAY", view_hash: "view-hash")
      @updated = nil
      payload = { type: action ? "block_actions" : "view_submission", user: { id: user_id }, trigger_id: "TRIGGER",
        view: @view.merge("id" => "VMODAL", "hash" => view_hash,
          "state" => { "values" => { "checkout_note" => { "checkout_note" => { "value" => note } },
            "checkout_reason" => { "checkout_reason" => { "value" => reason } } } }) }
      if action
        block ||= action.end_with?("_select") ? action.delete_suffix("_select") :
          (action == "checkout_back" ? "checkout_navigation" : "checkout_actions")
        payload[:actions] = [{ action_id: action, block_id: block,
          selected_option: { value: value, text: { type: "plain_text", text: display } } }]
      end
      post "/slack/interactions", params: { payload: payload.to_json }
      expect(response).to have_http_status(:ok)
      @view = @updated || response.parsed_body["view"] || @view
      expect(@view["private_metadata"].length).to be <= 3000
      expect(@view).to have_key("submit") if @view["blocks"].any? { |block| block["type"] == "input" }
      response.parsed_body
    end

    def choose_request(row)
      interact(action: "checkout_menu_select", value: "requests")
      interact(action: "checkout_request_select", value: row.id.to_s)
    end

    it "renders all four menu choices and binds the initiating identity and shop" do
      start_modal
      options = @view.fetch("blocks").find { |block| block["block_id"] == "checkout_menu" }.dig("accessory", "options")
      expect(@view["blocks"].none? { |block| block["type"] == "input" }).to be(true)
      expect(options.map { |option| option.dig("text", "text") }).to eq(["View my checkouts", "Request a checkout", "Volunteer to do checkouts", "View open requests"])
      expect(modal_metadata).to eq("member_id" => member.id.to_s, "shop_id" => shop.id.to_s,
        "slack_user_id" => "UMODAL", "response_url" => response_url, "step" => "menu")
      expect(@view["blocks"].map { |block| block["block_id"] }).not_to include("checkout_shop")
    end

    it "sorts enabled shops, allows shop-first navigation, and locks that shop on return" do
      z = create(:shop, name: "Zebra")
      a = create(:shop, name: "alpha")
      create(:shop, name: "Hidden", disabled: true)
      start_modal(selected_shop: nil)
      selector = @view["blocks"].find { |block| block["block_id"] == "checkout_shop" }
      expect(selector.dig("accessory", "options").map { |option| option["value"] }).to eq([a.id.to_s, z.id.to_s])
      interact(action: "checkout_shop_select", value: a.id.to_s)
      expect(modal_step).to eq("menu")
      interact(action: "checkout_menu_select", value: "active")
      interact(action: "checkout_back")
      expect(modal_metadata["shop_id"]).to eq(a.id.to_s)
      expect(@view["blocks"].map { |block| block["block_id"] }).not_to include("checkout_shop")
      interact(action: "checkout_shop_select", value: z.id.to_s)
      expect(modal_step).to eq("alert")
    end

    it "supports every menu-first shop selection and back navigation without a shop" do
      tool
      %w[active request_tools volunteer requests].each do |destination|
        start_modal(selected_shop: nil)
        interact(action: "checkout_menu_select", value: destination)
        expect(modal_step).to eq("shop_#{destination}")
        interact(action: "checkout_back")
        expect(modal_step).to eq("menu")
        interact(action: "checkout_menu_select", value: destination)
        interact(action: "checkout_shop_select", value: shop.id.to_s)
        expect(modal_step).to eq(destination)
      end
    end

    it "retains a volunteer request when backing out of either RM decision" do
      member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      volunteer = create(:member, :current)
      create(:tool_checkout, member: volunteer, tool: tool)
      request = CheckoutApproverRequest.create!(member: volunteer, tool: tool)

      %w[checkout_approve_volunteer checkout_decline_volunteer].each do |decision|
        start_modal
        interact(action: "checkout_menu_select", value: "requests")
        interact(action: "checkout_request_select", value: "volunteer:#{request.id}")
        interact(action: decision)
        interact(action: "checkout_back")
        expect(modal_step).to eq("volunteer_detail")
        expect(modal_metadata["record_id"]).to eq(request.id.to_s)
      end
    end

    it "selects an eligible tool by ID, creates a request, and preserves context through back navigation" do
      tool
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s, display: "Other tool - approve as admin")
      expect(modal_step).to eq("request_new")
      interact(action: "checkout_back")
      expect(modal_step).to eq("request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      expect(interact(note: "Please train me")["response_action"]).to eq("clear")
      expect(ToolCheckoutRequest.last).to have_attributes(member_id: member.id, tool_id: tool.id, note: "Please train me")
      start_modal
      expect(modal_step).to eq("menu")
      expect(modal_metadata["response_url"]).to eq(response_url)
      expect(Service::SlackConnector).to have_received(:update_modal).with("VMODAL", anything, hash: "view-hash").at_least(:once)
    end

    it "edits only the owner's note and cancels after confirmation, including every request back transition" do
      row = ToolCheckoutRequest.create!(member: member, tool: tool, note: "Original")
      start_modal
      choose_request(row)
      expect(modal_step).to eq("request_detail")
      interact(action: "checkout_edit_note")
      expect(modal_step).to eq("request_edit")
      interact(action: "checkout_back")
      expect(modal_step).to eq("request_detail")
      interact(action: "checkout_edit_note")
      result = interact(note: "x" * 129)
      expect(result).to include("response_action" => "errors", "errors" => { "checkout_note" => "Note must be at most 128 characters." })
      expect(row.reload.note).to eq("Original")
      interact(note: "Changed")
      expect(row.reload.note).to eq("Changed")
      start_modal
      choose_request(row)
      interact(action: "checkout_cancel_request")
      expect(row.reload).to be_open
      interact(action: "checkout_back")
      expect(modal_step).to eq("request_detail")
      interact(action: "checkout_back")
      expect(modal_step).to eq("requests")
      interact(action: "checkout_request_select", value: row.id.to_s)
      interact(action: "checkout_cancel_request")
      expect_any_instance_of(ToolCheckoutRequest).not_to receive(:remove_announcement)
      interact
      expect(row.reload.status).to eq("deleted")
      expect(CheckoutNotificationJob).to have_been_enqueued.with("cancellation", row.id.to_s)
    end

    it "approves an authorized request, closes it, and does not duplicate approvals on replay" do
      member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      expect(modal_step).to eq("request_approve")
      interact(action: "checkout_back")
      expect(modal_step).to eq("request_detail")
      interact(action: "checkout_approve_request")
      approval_view = @view.deep_dup
      interact
      checkout = ToolCheckout.last
      expect(checkout).to have_attributes(member_id: row.member_id, tool_id: tool.id, approved_by_id: member.id, signed_off_via: "slack")
      expect(row.reload).to have_attributes(status: "closed", checked_out_id: checkout.id)
      @view = approval_view
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckout.count).to eq(1)
    end

    it "shows active-checkout details only for the owner and supports both back transitions" do
      row = create(:tool_checkout, member: member, tool: tool)
      tool.update!(notes: "Private combination")
      start_modal
      interact(action: "checkout_menu_select", value: "active")
      interact(action: "checkout_checkout_select", value: row.id.to_s)
      expect(modal_step).to eq("checkout_detail")
      expect(@view.to_json).to include("Private combination")
      interact(action: "checkout_back")
      expect(modal_step).to eq("active")
      interact(action: "checkout_back")
      expect(modal_step).to eq("menu")
    end

    it "rejects a checkout owned by another member and never renders its notes" do
      tool.update!(notes: "PRIVATE")
      row = create(:tool_checkout, member: create(:member, :current), tool: tool)
      start_modal
      interact(action: "checkout_menu_select", value: "active")
      interact(action: "checkout_checkout_select", value: row.id.to_s)
      expect(modal_step).to eq("alert")
      expect(@view.to_json).not_to include("PRIVATE")
    end

    it "rejects request editing and cancellation by an approver who is not the owner" do
      member.update!(role: "admin")
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      %w[checkout_edit_note checkout_cancel_request].each do |action|
        start_modal
        choose_request(row)
        interact(action: action)
        expect(modal_step).to eq("alert")
        expect(row.reload).to be_open
      end
    end

    it "rejects request visibility and approval outside assigned tool scope" do
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      create(:checkout_approver, member: member, tool_ids: [create(:tool, shop: shop).id.to_s], shop_ids: [])
      start_modal
      choose_request(row)
      expect(modal_step).to eq("alert")
      expect(@view.to_json).not_to include(row.member.fullname)
      expect(ToolCheckout.count).to eq(0)
    end

    it "rechecks approval permissions after confirmation has opened" do
      approver = create(:checkout_approver, member: member, tool_ids: [tool.id.to_s], shop_ids: [])
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      approver.destroy!
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckout.count).to eq(0)
      expect(row.reload).to be_open
    end

    it "rejects cross-shop tools, requests, and checkouts even with forged option labels" do
      foreign_tool = create(:tool)
      foreign_request = ToolCheckoutRequest.create!(member: member, tool: foreign_tool)
      foreign_checkout = create(:tool_checkout, member: member, tool: create(:tool, shop: foreign_tool.shop))
      [["request_tools", "checkout_tool_select", foreign_tool], ["requests", "checkout_request_select", foreign_request],
       ["active", "checkout_checkout_select", foreign_checkout]].each do |menu, action, row|
        start_modal
        interact(action: "checkout_menu_select", value: menu)
        interact(action: action, value: row.id.to_s, display: tool.name)
        expect(modal_step).to eq("alert")
      end
    end

    it "rejects invalid and deleted tool IDs" do
      ["not-an-id", BSON::ObjectId.new.to_s].each do |id|
        start_modal
        interact(action: "checkout_menu_select", value: "request_tools")
        interact(action: "checkout_tool_select", value: id)
        expect(modal_step).to eq("alert")
      end
    end

    it "rejects expired metadata and a shop deleted after opening" do
      start_modal
      travel 61.minutes do
        interact(action: "checkout_menu_select", value: "active")
        expect(modal_step).to eq("alert")
      end
      start_modal
      shop.destroy!
      interact(action: "checkout_menu_select", value: "requests")
      expect(modal_step).to eq("alert")
    end

    it "rejects a disabled shop on both selection and subsequent navigation" do
      start_modal(selected_shop: nil)
      shop.update!(disabled: true)
      interact(action: "checkout_shop_select", value: shop.id.to_s)
      expect(modal_step).to eq("alert")
      start_modal
      interact(action: "checkout_menu_select", value: "active")
      expect(modal_step).to eq("alert")
    end

    it "rechecks a tool disabled after selection and refuses creation" do
      tool
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      tool.update!(disabled: true)
      interact(note: "Still available?")
      expect(modal_step).to eq("alert")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "rejects stale, closed and deleted requests" do
      row = ToolCheckoutRequest.create!(member: member, tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_edit_note")
      row.update!(status: "closed")
      interact(note: "stale")
      expect(modal_step).to eq("alert")
      row.destroy!
      start_modal
      choose_request(row)
      expect(modal_step).to eq("alert")
    end

    it "rejects a revoked checkout after its details have opened" do
      row = create(:tool_checkout, member: member, tool: tool)
      start_modal
      interact(action: "checkout_menu_select", value: "active")
      interact(action: "checkout_checkout_select", value: row.id.to_s)
      row.update!(revoked_at: Time.current)
      interact(action: "checkout_back")
      expect(modal_step).to eq("alert")
    end

    %w[revoked suspended inactive nonMember].each do |status|
      it "rechecks an acting member changed to #{status} after opening" do
        start_modal
        member.update!(status: status)
        interact(action: "checkout_menu_select", value: "requests")
        expect(modal_step).to eq("alert")
        expect(ToolCheckoutRequest.count).to eq(0)
      end
    end

    it "rechecks expiration after opening" do
      start_modal
      member.update!(expirationTime: 1)
      interact(action: "checkout_menu_select", value: "active")
      expect(modal_step).to eq("alert")
      expect(@view.to_json).to include("expired")
    end

    it "allows pending members only on tools allowing pending, including after selection" do
      member.update!(status: "pending", expirationTime: nil)
      tool.update!(allow_pending: true)
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      expect(modal_step).to eq("request_new")
      tool.update!(allow_pending: false)
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "rejects approval when the requester becomes ineligible" do
      member.update!(role: "admin")
      requester = create(:member, :current)
      row = ToolCheckoutRequest.create!(member: requester, tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      requester.update!(status: "suspended")
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckout.count).to eq(0)
    end

    it "rejects another Slack identity, changed account links and tampered metadata" do
      start_modal
      interact(action: "checkout_menu_select", value: "active", user_id: "OTHER")
      expect(modal_step).to eq("alert")
      start_modal
      SlackUser.collection.find(slack_id: "UMODAL").update_one('$set' => { member_id: create(:member, :current).id })
      interact(action: "checkout_menu_select", value: "active")
      expect(modal_step).to eq("alert")
      start_modal
      @view["private_metadata"] = '{"member_id":"forged","shop_id":"forged"}'
      interact(action: "checkout_menu_select", value: "active")
      expect(modal_step).to eq("alert")
    end

    it "rejects forged action IDs and submissions from non-submittable steps" do
      start_modal
      interact(action: "checkout_approve_request")
      expect(modal_step).to eq("alert")
      start_modal
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckout.count).to eq(0)
    end

    it "keeps field errors on the request note and rejects duplicate submissions" do
      tool
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      form = @view.deep_dup
      expect(interact(note: "x" * 129).dig("errors", "checkout_note")).to include("128")
      interact(note: "valid")
      @view = form
      interact(note: "duplicate")
      expect(modal_step).to eq("alert")
      expect(ToolCheckoutRequest.count).to eq(1)
    end

    it "does not write when another interaction holds the checkout lock" do
      tool
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      allow(REDIS).to receive(:set).and_return(false)
      interact
      expect(modal_step).to eq("alert")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "reports views.update failures without overwriting a concurrent view or mutating records" do
      start_modal
      allow(Service::SlackConnector).to receive(:update_modal).and_raise(StandardError, "hash_conflict")
      expect(interact(action: "checkout_menu_select", value: "requests")).to eq({})
      expect(Service::SlackConnector).to have_received(:update_modal).with("VMODAL", anything, hash: "view-hash").once
      expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "checkout_modal"))
      expect(Service::ErrorReporter).to have_received(:notify).with(anything, context: { phase: "checkout modal views.update" })
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "queues replacement before clearing a successful request and never calls response HTTP inline" do
      tool
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      expect(Net::HTTP).not_to receive(:start)
      expect(SlackCheckoutOutcomeJob).to receive(:enqueue).with(include(tool.name), response_url, "UMODAL") do
        expect(ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id)).to exist
        true
      end
      expect(interact(note: "Train me")).to eq("response_action" => "clear")
    end

    it "acknowledges request persistence without running Slack side effects" do
      start_modal
      interact(action: "checkout_menu_select", value: "request_tools")
      interact(action: "checkout_tool_select", value: tool.id.to_s)
      expect_any_instance_of(ToolCheckoutRequest).not_to receive(:announce_request)
      expect(Service::SlackConnector).not_to receive(:send_slack_message)
      expect(interact(note: "Train me")).to eq("response_action" => "clear")
      expect(CheckoutNotificationJob).to have_been_enqueued.with("request", ToolCheckoutRequest.last.id.to_s)
    end

    it "acknowledges approval before invitation, DMs, announcements or audit Slack calls" do
      member.update!(role: "admin")
      tool.update!(users_channel: "tool-users")
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      expect_any_instance_of(ToolCheckout).not_to receive(:invite_member_to_users_channel)
      expect_any_instance_of(ToolCheckout).not_to receive(:send_checkout_slack_notification)
      expect_any_instance_of(ToolCheckout).not_to receive(:announce_checkout_success)
      expect(Service::AuditLogger).not_to receive(:log)
      expect(Service::SlackConnector).not_to receive(:send_slack_message)
      expect(interact).to eq("response_action" => "clear")
      expect(row.reload.status).to eq("closed")
      expect(CheckoutNotificationJob).to have_been_enqueued.with("approval", row.checked_out_id.to_s)
    end

    it "clears a persisted approval when side-effect enqueueing fails" do
      member.update!(role: "admin")
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      allow(CheckoutNotificationJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
      expect(interact).to eq("response_action" => "clear")
      expect(row.reload.status).to eq("closed")
      expect(Service::ErrorReporter).to have_received(:notify).with("Checkout notification failed", context: { error_class: "StandardError" })
    end

    it "clears an approved request even if enqueueing raises after persistence" do
      member.update!(role: "admin")
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_approve_request")
      allow(SlackCheckoutOutcomeJob).to receive(:enqueue).and_raise(StandardError, response_url)
      expect(interact).to eq("response_action" => "clear")
      expect(row.reload.status).to eq("closed")
      expect(Service::ErrorReporter).to have_received(:notify).with("Slack checkout outcome enqueue failed", context: hash_including(error_class: "StandardError"))
    end

    it "declines an authorized request with a required reason and queues the requester notification" do
      member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      row = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)
      start_modal
      choose_request(row)
      interact(action: "checkout_decline_request")
      expect(modal_step).to eq("request_decline")
      reason_block = @view["blocks"].find { |block| block["block_id"] == "checkout_reason" }
      expect(reason_block).to include("optional" => false)
      interact(action: "checkout_back")
      expect(modal_step).to eq("request_detail")
      interact(action: "checkout_decline_request")

      expect(interact(reason: "  ").to_h).to include("response_action" => "errors")
      expect(row.reload).to be_open
      expect(interact(reason: "x" * 256).to_h).to include("response_action" => "errors")
      expect(row.reload).to be_open

      expect(interact(reason: "Needs the safety class first")["response_action"]).to eq("clear")
      expect(row.reload).to have_attributes(status: "declined", decided_by_id: member.id,
                                            decision_reason: "Needs the safety class first")
      expect(CheckoutNotificationJob).to have_been_enqueued.with("decline", row.id.to_s)
      expect(ToolCheckout.where(member_id: row.member_id, tool_id: tool.id).count).to eq(0)
    end

    it "keeps owner and non-owner request actions separate and shows persisted dates" do
      member.update!(role: "admin")
      own = ToolCheckoutRequest.create!(member: member, tool: tool, note: "Owner note")
      other = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool, note: "Other note")
      start_modal
      choose_request(own)
      ids = @view["blocks"].flat_map { |block| Array(block["elements"]).map { |element| element["action_id"] } }
      expect(ids).to contain_exactly("checkout_edit_note", "checkout_cancel_request", "checkout_back")
      expect(@view.to_json).to include(own.request_date.iso8601, "Owner note")
      start_modal
      choose_request(other)
      ids = @view["blocks"].flat_map { |block| Array(block["elements"]).map { |element| element["action_id"] } }
      expect(ids).to contain_exactly("checkout_approve_request", "checkout_decline_request", "checkout_back")
      expect(@view.to_json).to include(other.request_date.iso8601, other.member.fullname, shop.name, tool.name, "Other note")
    end

    it "renders bounded active details with description, notes, channel, wiki, date and reservability" do
      tool.update!(description: "x" * 4000, notes: "Private notes", users_channel: "tools", wiki_url: "https://example.test/tool", reservable: true)
      allow(Service::SlackConnector).to receive(:channel_member?).and_return(true)
      checkout = create(:tool_checkout, member: member, tool: tool)
      start_modal
      interact(action: "checkout_menu_select", value: "active")
      interact(action: "checkout_checkout_select", value: checkout.id.to_s)
      content = @view["blocks"].filter_map { |block| block.dig("text", "text") }
      expect(content.join).to include("Description:", "Private notes", "#tools", "https://example.test/tool", checkout.checked_out_at.to_date.iso8601, "Reservable: Yes")
      expect(content.all? { |line| line.length <= 3000 }).to be(true)
      expect(@view["blocks"].any? { |block| block["block_id"] == "checkout_navigation" }).to be(true)
    end

    it "refuses to update a modal without its concurrency hash" do
      start_modal
      expect(interact(action: "checkout_menu_select", value: "requests", view_hash: nil)).to eq({})
      expect(Service::SlackConnector).not_to have_received(:update_modal)
      expect(Service::SlackConnector).to have_received(:open_modal)
    end

    it "acknowledges safely if both update and its alert fallback fail" do
      start_modal
      allow(Service::SlackConnector).to receive(:update_modal).and_raise(StandardError)
      allow(Service::SlackConnector).to receive(:open_modal).and_raise(StandardError)
      expect(interact(action: "checkout_menu_select", value: "requests")).to eq({})
    end
  end

  context "with a reservation interaction" do
    let(:member) { create(:member, :current) }
    let(:response_url) { "https://hooks.slack.test/responses/secret" }
    let(:metadata) do
      { member_id: member.id.to_s, shop_id: BSON::ObjectId.new.to_s,
        response_url: response_url, slack_user_id: "UINITIATOR" }
    end

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      allow(Service::ErrorReporter).to receive(:notify)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    def reservation_payload(type: "view_submission", date: "2027-01-02", start_time: "10:00", duration: "hours:1.0")
      {
        type: type, user: { id: "USUBMITTER" },
        view: {
          callback_id: "reservation_submit", private_metadata: metadata.to_json,
          state: { values: {
            title: { title: { value: "Lathe time" } },
            scope: { SlackReservationModal::SCOPE_ACTION_ID => { selected_option: { value: "shop" } } },
            date: { date: { selected_date: date } },
            start_time: { start_time: { selected_time: start_time } },
            duration: { duration: { selected_option: { value: duration } } }
          } }
        }
      }
    end

    it "converts a selected duration into the reservation end time" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!) do |arguments|
        attributes = arguments.fetch(:attributes)
        expect(attributes[:start_at]).to eq(ReservationService::ZONE.parse("2027-01-02 10:00"))
        expect(attributes[:end_at]).to eq(ReservationService::ZONE.parse("2027-01-02 12:30"))
        expect(attributes[:full_day]).to be(false)
        reservation
      end
      post "/slack/interactions", params: {
        payload: reservation_payload(duration: "hours:2.5").to_json
      }

      expect(response.parsed_body).to eq("response_action" => "clear")
    end

    it "advances whole-day durations across daylight-saving changes by local dates" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!) do |arguments|
        attributes = arguments.fetch(:attributes)
        expect(attributes[:start_at].in_time_zone(ReservationService::ZONE)).to eq(
          ReservationService::ZONE.local(2027, 3, 14)
        )
        expect(attributes[:end_at].in_time_zone(ReservationService::ZONE)).to eq(
          ReservationService::ZONE.local(2027, 3, 15)
        )
        expect(attributes[:end_at] - attributes[:start_at]).to eq(23.hours)
        expect(attributes[:full_day]).to be(true)
        reservation
      end
      post "/slack/interactions", params: {
        payload: reservation_payload(date: "2027-03-14", duration: "days:1").to_json
      }

      expect(response.parsed_body).to eq("response_action" => "clear")
    end

    it "returns an error on the duration block when server policy rejects the duration" do
      expect(ReservationService).to receive(:create!)
        .and_raise(Error::UnprocessableEntity.new("Reservation exceeds the maximum duration"))

      post "/slack/interactions", params: {
        payload: reservation_payload(duration: "hours:9.0").to_json
      }

      expect(response.parsed_body).to include(
        "response_action" => "errors",
        "errors" => { "duration" => "Reservation exceeds the maximum duration" }
      )
    end

    {
      "A title is required" => "title",
      "Reservation date is outside the booking window" => "date",
      "Start time does not satisfy advance notice" => "start_time",
      "The selected resource is not reservable" => "scope"
    }.each do |message, block_id|
      it "puts #{block_id} policy errors beside the relevant field" do
        allow(ReservationService).to receive(:create!)
          .and_raise(Error::UnprocessableEntity.new(message))

        post "/slack/interactions", params: { payload: reservation_payload.to_json }

        expect(response.parsed_body).to include(
          "response_action" => "errors",
          "errors" => { block_id => message }
        )
      end
    end

    it "shows broad fee confirmation failures in a modal alert" do
      shop = instance_double(Shop)
      updated_view = { type: "modal", submit: { type: "plain_text", text: "Use Member Portal" } }
      allow(ReservationService).to receive(:create!).and_raise(
        Error::UnprocessableEntity.new("Please review and approve the reservation fee of $12.50")
      )
      allow(Shop).to receive(:find).with(metadata[:shop_id]).and_return(shop)
      expect(SlackReservationModal).to receive(:update).with(hash_including(
        shop: shop,
        alert_message: include("$12.50")
      )).and_return(updated_view)

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq(
        "response_action" => "update",
        "view" => updated_view.deep_stringify_keys
      )
    end

    it "rebuilds the modal policy and preserves state after resource block actions" do
      shop = instance_double(Shop)
      rebuilt_view = { type: "modal", blocks: [] }
      allow(Shop).to receive(:find).with(metadata[:shop_id]).and_return(shop)
      allow(Member).to receive(:find).with(member.id.to_s).and_return(member)
      expect(SlackReservationModal).to receive(:update).with(
        shop: shop,
        member: member,
        read_context: instance_of(ReservationReadContext),
        response_url: response_url,
        slack_user_id: "UINITIATOR",
        reservation_scope: "shop",
        tool_ids: [],
        title: "Lathe time",
        date: "2027-01-02",
        start_time: "10:00",
        duration: "hours:1.0"
      ).and_return(rebuilt_view)
      expect(Service::SlackConnector).to receive(:update_modal)
        .with("V123", rebuilt_view, hash: "view-hash")
      payload = reservation_payload(type: "block_actions")
      payload[:view][:id] = "V123"
      payload[:view][:hash] = "view-hash"
      payload[:actions] = [{
        action_id: SlackReservationModal::SCOPE_ACTION_ID,
        selected_option: { value: "shop" }
      }]

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "re-resolves added tools and applies their strictest rules" do
      shop = create(:shop, max_reservation_duration_hours: 8)
      first = create(:tool, shop: shop, open: true, max_reservation_duration_hours: 8)
      strict = create(:tool, shop: shop, max_reservation_duration_hours: 3,
        reservation_horizon_days: 2, minimum_advance_notice_hours: 6, open: true)
      payload = reservation_payload(type: "block_actions", duration: "hours:8")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:id] = "VADD"
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [first, strict].map { |tool| { value: tool.id.to_s } }
      }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        duration = view[:blocks].find { |candidate| candidate[:block_id] == "duration" }
        details = view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }
        expect(duration.dig(:element, :initial_option, :value)).to eq("hours:3.0")
        expect(details.dig(:text, :text)).to include("2 days", "6 hours", first.name, strict.name)
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "preserves an empty tool selection after all tools are removed" do
      shop = create(:shop)
      create(:tool, shop: shop, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:id] = "VREMOVE"
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{ action_id: SlackReservationModal::TOOLS_ACTION_ID, selected_options: [] }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        expect(view.dig(:submit, :text)).to eq("Review selection")
        expect(view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }
          .dig(:text, :text)).to include("Select one or more tools")
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "rejects stale, disabled, non-reservable, and cross-shop tool IDs" do
      shop = create(:shop)
      allow(Service::SlackConnector).to receive(:update_modal)
      invalid_tools = [
        BSON::ObjectId.new.to_s,
        create(:tool, shop: shop, disabled: true).id.to_s,
        create(:tool, shop: shop, reservable: false).id.to_s,
        create(:tool).id.to_s
      ]

      invalid_tools.each do |tool_id|
        payload = reservation_payload(type: "block_actions")
        payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
        payload[:actions] = [{
          action_id: SlackReservationModal::TOOLS_ACTION_ID,
          selected_options: [{ value: tool_id }]
        }]
        post "/slack/interactions", params: { payload: payload.to_json }
        expect(response.parsed_body).to eq({})
      end

      expect(Service::SlackConnector).not_to have_received(:update_modal)
      expect(Service::ErrorReporter).to have_received(:notify).at_least(:once).with(
        instance_of(Error::UnprocessableEntity),
        context: hash_including(phase: "Slack reservation modal policy update")
      )
    end

    it "reports views.update failures without accepting submitted option data" do
      shop = create(:shop)
      tool = create(:tool, shop: shop, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [{ value: tool.id.to_s, text: { text: "Forged name" } }]
      }]
      allow(Service::SlackConnector).to receive(:update_modal).and_raise(StandardError, "Slack unavailable")

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError),
        context: hash_including(phase: "Slack reservation modal policy update")
      )
    end

    it "prevents submission for incompatible horizon and notice selections" do
      shop = create(:shop)
      horizon = create(:tool, shop: shop, name: "Today Only", reservation_horizon_days: 0, open: true)
      notice = create(:tool, shop: shop, name: "Tomorrow Only", prohibit_same_day_reservations: true, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [horizon, notice].map { |tool| { value: tool.id.to_s } }
      }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        expect(view.dig(:submit, :text)).to eq("Review selection")
        text = view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }.dig(:text, :text)
        expect(text).to include("Unavailable combination", "Today Only", "Tomorrow Only")
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }
    end

    it "rejects an incompatible tool combination against the tools input before creation" do
      shop = create(:shop)
      horizon = create(:tool, shop: shop, reservation_horizon_days: 0, open: true)
      notice = create(:tool, shop: shop, prohibit_same_day_reservations: true, open: true)
      payload = reservation_payload
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:view][:state][:values][:tools] = {
        SlackReservationModal::TOOLS_ACTION_ID => {
          selected_options: [horizon, notice].map { |tool| { value: tool.id.to_s } }
        }
      }
      expect(ReservationService).not_to receive(:create!)

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to include(
        "response_action" => "errors",
        "errors" => include("tools" => include("cannot be reserved together"))
      )
    end

    it "queues approved outcome delivery before clearing the modal" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      allow(ReservationService).to receive(:create!).and_return(reservation)

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
        include("approved"), response_url, "USUBMITTER"
      )
    end

    { "pending" => "pending approval", "unpaid" => "payment is required",
      "approved" => "approved" }.each do |status, text|
      it "uses the #{status} reservation outcome text" do
        details = status == "pending" ? [{ "message" => "Manager review" }] : []
        reservation = instance_double(
          Reservation, title: "Lathe time", status: status,
          effective_approval_details: details
        )
        allow(ReservationService).to receive(:create!).and_return(reservation)

        post "/slack/interactions", params: { payload: reservation_payload.to_json }
        expect(response.parsed_body).to eq("response_action" => "clear")
        expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
          include(text), response_url, "USUBMITTER"
        )
      end
    end

    it "queues modal closure outcome delivery" do
      expect(ReservationService).not_to receive(:create!)

      post "/slack/interactions", params: { payload: reservation_payload(type: "view_closed").to_json }

      expect(response.parsed_body).to eq({})
      expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
        include("cancelled without submission"), response_url, "USUBMITTER"
      )
    end

    it "clears the modal after creation even when outcome enqueueing fails" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!).and_return(reservation)
      allow(SlackReservationOutcomeJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError), context: hash_including(phase: "Slack reservation outcome delivery")
      )
    end
  end
end
