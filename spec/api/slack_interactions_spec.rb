require "swagger_helper"

describe "Slack interactions API", type: :request do
  path "/slack/interactions" do
    post "Handles signed Slack modal interactions",
      operation: { servers: [{ url: "/", description: "Application root" }] } do
      tags "SlackInteractions"
      operationId "slackInteractions"
      description "Callbacks: checkout_modal accepts block_actions and view_submission; checkout_request_submit accepts legacy submissions; reservation_submit also accepts view_closed. Checkout navigation calls views.update with the incoming view hash. Successful checkout submissions persist under the member/tool lock and enqueue request/cancellation announcements or approval invitations, DMs, success announcements and audit logging; request submissions also DM the linked requestor with the tool annotation or shop fallback; these Slack side effects, including volunteer-review and decision DMs, run in CheckoutNotificationJob outside the acknowledgement path. Submissions also enqueue replacement-first ephemeral outcome delivery and return response_action clear, even if enqueueing fails. The outcome job falls back to the submitting Slack user DM on replacement failure. Rejected submissions return response_action update with an explanatory modal, or errors keyed by input block ID. Checkout private_metadata is a signed, expiring contract containing member_id, optional shop_id, response_url, slack_user_id, step and optional record_id. Every transition reloads and authorizes these IDs. Display text is never an identifier. Checkout action IDs: checkout_menu_select, checkout_shop_select, checkout_tool_select, checkout_request_select, checkout_checkout_select, checkout_edit_note, checkout_cancel_request, checkout_approve_request, checkout_decline_request, checkout_approve_volunteer, checkout_decline_volunteer, checkout_back. Note input block/action ID: checkout_note. Declining a request requires a reason (at most 255 characters) in the required input with block/action ID checkout_reason; a missing or overlong reason returns errors keyed by checkout_reason, and a successful decline DMs the requester."
      consumes "application/x-www-form-urlencoded"
      produces "application/json"
      parameter name: :"X-Slack-Signature", in: :header, type: :string,
        required: true, description: "Slack v0 request signature"
      parameter name: :"X-Slack-Request-Timestamp", in: :header, type: :string,
        required: true, description: "Unix timestamp covered by the Slack signature"
      parameter name: :interaction, in: :body, schema: {
        type: :object,
        properties: {
          payload: {
            type: :string,
            pattern: '"type"\s*:\s*"(view_submission|block_actions|view_closed)"',
            description: "JSON-encoded Slack interaction. Reservation views accept view_submission, " \
              "view_closed, and block_actions; checkout_modal accepts block_actions and view_submission. Block actions include actions and current view state. Checkout field errors use checkout_note. Echo the opaque private_metadata unchanged; do not construct it from this example. Submissions supply view.state.values.checkout_note.checkout_note.value (optional string, maximum 128 characters). Menu values are active, request_tools, volunteer and requests; checkout_request_select uses a persisted request ID for checkout requests or volunteer:<request_id> for volunteer rows; other selectors use persisted record IDs.",
            example: {
              type: "block_actions",
              user: { id: "U12345678" },
              actions: [{ block_id: "checkout_menu", action_id: "checkout_menu_select",
                selected_option: { text: { type: "plain_text", text: "View my checkouts" }, value: "active" } }],
              view: {
                id: "V12345678",
                hash: "view-hash",
                callback_id: "checkout_modal",
                private_metadata: "<opaque signed metadata returned by views.open>",
                state: { values: {} }
              }
            }.to_json
          }
        },
        required: ["payload"]
      }

      response "200", "interaction acknowledged or modal response returned" do
        example "application/json", :navigation, {}, "Block-action acknowledgement",
          "The server calls views.update using view.id and view.hash; no view is returned in the HTTP acknowledgement. Failed updates also acknowledge with {}, report the failure and attempt a separate alert without retrying without the hash."
        example "application/json", :saved, { response_action: "clear" }, "Checkout write saved",
          "Request creation, cancellation and approval queue their Slack side effects rather than executing them before acknowledgement. All saved mutations enqueue final outcome delivery before clearing. Delivery or enqueue failure does not undo persistence."
        example "application/json", :note_error, {
          response_action: "errors", errors: { checkout_note: "Note must be at most 128 characters." }
        }, "Field-specific validation"
        example "application/json", :stale, {
          response_action: "update", view: { type: "modal", callback_id: "checkout_modal",
            title: { type: "plain_text", text: "Checkouts" },
            private_metadata: "<opaque signed alert metadata>",
            blocks: [{ type: "section", text: { type: "plain_text", text: "This shop is no longer available." } }] }
        }, "Stale or unauthorized submission", "The replacement view explains the failure; no write is performed."
        let(:"X-Slack-Signature") { "v0=documented-by-signature-header" }
        let(:"X-Slack-Request-Timestamp") { Time.current.to_i.to_s }
        let(:interaction) do
          { payload: { type: "view_closed", view: { callback_id: "unrelated_view" } }.to_json }
        end

        before do
          allow_any_instance_of(Slack::InteractionsController)
            .to receive(:verify_slack_signature)
        end

        schema type: :object,
          description: "Empty acknowledgement, modal clear action, field validation errors, or a modal update containing a checkout/reservation view or explanatory alert",
          properties: {
            response_action: { type: :string, enum: %w[clear update errors] },
            errors: { type: :object, additionalProperties: { type: :string }, description: "Input block ID to validation message, including checkout_note" },
            view: { type: :object, properties: {
              type: { type: :string, enum: ["modal"] },
              callback_id: { type: :string, enum: %w[checkout_modal checkout_request_submit reservation_submit] },
              private_metadata: { type: :string },
              blocks: { type: :array, items: { type: :object } }
            }, required: %w[type callback_id blocks] }
          }, additionalProperties: true

        it "documents and acknowledges view closure payloads" do
          post "/slack/interactions", params: interaction, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to eq({})
        end

        context "with checkout modal callbacks" do
          let(:member) { create(:member, :current) }
          let(:shop) { create(:shop) }
          let(:tool) { create(:tool, shop: shop) }
          before do
            SlackUser.create!(member: member, slack_id: "UCHECKOUT")
            allow(Service::SlackConnector).to receive(:update_modal)
          end

          def checkout_view(step: "menu", record_id: nil)
            metadata = { "member_id" => member.id.to_s, "shop_id" => shop.id.to_s,
              "slack_user_id" => "UCHECKOUT", "response_url" => "https://hooks.slack.com/commands/example",
              "step" => step, "record_id" => record_id }.compact
            SlackCheckoutModal.new(member: member, shop: shop, tool: tool, metadata: metadata).build
              .merge(id: "VCHECKOUT", hash: "current-hash")
          end

          it "acknowledges checkout block_actions and updates the modal with its hash" do
            payload = { type: "block_actions", user: { id: "UCHECKOUT" }, view: checkout_view,
              actions: [{ action_id: "checkout_menu_select", block_id: "checkout_menu",
                selected_option: { value: "active" } }] }
            post "/slack/interactions", params: { payload: payload.to_json }
            expect(response.parsed_body).to eq({})
            expect(Service::SlackConnector).to have_received(:update_modal).with("VCHECKOUT", hash_including(callback_id: "checkout_modal"), hash: "current-hash")
          end

          it "clears saved submissions after queueing replacement-first delivery" do
            allow(REDIS).to receive(:set).and_return(true)
            allow(REDIS).to receive(:eval).and_return(1)
            allow(SlackCheckoutOutcomeJob).to receive(:enqueue).and_return(true)
            allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
            view = checkout_view(step: "request_new", record_id: tool.id.to_s)
            view[:state] = { values: { checkout_note: { checkout_note: { value: "Please arrange training" } } } }
            post "/slack/interactions", params: { payload: { type: "view_submission", user: { id: "UCHECKOUT" }, view: view }.to_json }
            expect(response).to have_http_status(:ok)
            expect(response.parsed_body).to eq("response_action" => "clear")
            expect(ToolCheckoutRequest.where(member: member, tool: tool, status: "open").first.note).to eq("Please arrange training")
            expect(CheckoutNotificationJob).to have_been_enqueued.with("request", ToolCheckoutRequest.last.id.to_s)
            expect(SlackCheckoutOutcomeJob).to have_received(:enqueue).with(anything, "https://hooks.slack.com/commands/example", "UCHECKOUT")
          end

          it "acknowledges modal-update failure and attempts a separate alert" do
            allow(Service::SlackConnector).to receive(:update_modal).and_raise(StandardError)
            allow(Service::SlackConnector).to receive(:open_modal)
            allow(Service::ErrorReporter).to receive(:notify)
            payload = { type: "block_actions", trigger_id: "TALERT", user: { id: "UCHECKOUT" }, view: checkout_view,
              actions: [{ action_id: "checkout_menu_select", block_id: "checkout_menu", selected_option: { value: "active" } }] }
            post "/slack/interactions", params: { payload: payload.to_json }
            expect(response.parsed_body).to eq({})
            expect(Service::SlackConnector).to have_received(:update_modal).once.with("VCHECKOUT", anything, hash: "current-hash")
            expect(Service::SlackConnector).to have_received(:open_modal).with("TALERT", hash_including(callback_id: "checkout_modal"))
          end

          it "returns checkout submission field errors keyed by block ID" do
            view = checkout_view(step: "request_new", record_id: tool.id.to_s)
            view[:state] = { values: { checkout_note: { checkout_note: { value: "x" * 129 } } } }
            post "/slack/interactions", params: { payload: { type: "view_submission", user: { id: "UCHECKOUT" }, view: view }.to_json }
            expect(response.parsed_body).to include("response_action" => "errors", "errors" => { "checkout_note" => "Note must be at most 128 characters." })
          end

          it "returns a modal update explaining authorization changes" do
            view = checkout_view(step: "request_new", record_id: tool.id.to_s)
            member.update!(status: "inactive")
            post "/slack/interactions", params: { payload: { type: "view_submission", user: { id: "UCHECKOUT" }, view: view }.to_json }
            expect(response.parsed_body).to include("response_action" => "update", "view" => hash_including("callback_id" => "checkout_modal"))
            expect(response.parsed_body.dig("view", "blocks").to_json).to include("inactive")
          end
        end
      end

      response "403", "Slack signature is missing, invalid, or stale" do
        schema type: :object,
          properties: { error: { type: :string } },
          required: ["error"]

        let(:interaction) { { payload: {}.to_json } }
        let(:"X-Slack-Signature") { "v0=stale" }
        let(:"X-Slack-Request-Timestamp") { 10.minutes.ago.to_i.to_s }

        before do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return("documented-secret")
        end

        it "rejects a stale interaction" do
          post "/slack/interactions", params: interaction, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body).to eq("error" => "Request too old")
        end
      end
    end
  end
end
