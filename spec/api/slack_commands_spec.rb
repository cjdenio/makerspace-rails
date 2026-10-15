require "swagger_helper"

describe "Slack commands API", type: :request do
  path "/slack/commands/checkout" do
    post "Handles the Slack checkout slash command",
      operation: { servers: [{ url: "/", description: "Application root" }] } do
      tags "SlackCommands"
      operationId "slackCheckoutCommand"
      consumes "application/x-www-form-urlencoded"
      produces "application/json"
      parameter name: :"X-Slack-Signature", in: :header, type: :string,
        required: true, description: "Slack v0 request signature"
      parameter name: :"X-Slack-Request-Timestamp", in: :header, type: :string,
        required: true, description: "Unix timestamp covered by the Slack signature"
      parameter name: :command_details, in: :body, schema: {
        type: :object,
        properties: {
          command: { type: :string, example: "/checkout" },
          text: {
            type: :string,
            description: "Empty text opens the stateful checkout menu (my checkouts, request a checkout, volunteer to do checkouts, open requests). Shop channels lock the shop; elsewhere the modal offers enabled shops. Linked pending members may enter; expired, revoked, suspended and inactive members receive specific ephemeral errors. Textual MEMBER GROUP opens a signed group review synchronously using trigger_id; unknown target identities should use their linked Member Portal email. Legacy text: MEMBER TOOL, request [TOOL], active|list [all], volunteer, or help. Active lists share the modal query and detail fields; final results replace the initial ephemeral response asynchronously, with DM fallback."
          },
          trigger_id: { type: :string, example: "T12345678", description: "Required to open the checkout modal (empty text, MEMBER GROUP, volunteer, or legacy request without a tool)" },
          channel_id: { type: :string },
          channel_name: { type: :string },
          user_id: { type: :string },
          user_name: { type: :string },
          response_url: { type: :string, format: :uri }
        },
        required: %w[text channel_id channel_name user_id response_url]
      }

      response "200", "command accepted or membership/modal failure explained ephemerally" do
        example "application/json", :menu, { response_type: "ephemeral", text: "Opening checkout menu..." },
          "Bare /checkout", "The server calls views.open; the modal is not embedded in this HTTP response."
        example "application/json", :active, { response_type: "ephemeral", text: "Looking up your active checkouts..." },
          "Compatibility active command"
        example "application/json", :expired, { response_type: "ephemeral", text: "Your membership has expired. Renew it before using checkouts." },
          "Ineligible linked member", "No modal opens; this is distinct from an unlinked Slack account."
        example "application/json", :open_failed, { response_type: "ephemeral", text: "The checkout menu could not be opened. Please try /checkout again." },
          "Modal opening failed"
        let(:"X-Slack-Signature") { "v0=documented-by-signature-header" }
        let(:"X-Slack-Request-Timestamp") { Time.current.to_i.to_s }
        let(:command_details) do
          {
            command: "/checkout",
            text: "active",
            channel_id: "C12345678",
            channel_name: "woodshop",
            user_id: "U12345678",
            user_name: "member",
            response_url: "https://hooks.slack.com/commands/response"
          }
        end

        before do
          allow_any_instance_of(Slack::CommandsController)
            .to receive(:verify_slack_signature)
          allow(SlackCheckoutActiveJob).to receive(:perform_later)
        end

        schema type: :object,
          properties: {
            response_type: { type: :string, enum: ["ephemeral"] },
            text: { type: :string }
          },
          required: %w[response_type text]

        context "with a bare checkout command" do
          let(:member) { create(:member, :current) }
          let(:shop) { create(:shop, slack_channel: "C12345678") }
          before do
            shop
            SlackUser.create!(member: member, slack_id: "U12345678")
            allow(Service::SlackConnector).to receive(:open_modal)
          end

          it "opens the four-option menu with the configured shop fixed" do
            post "/slack/commands/checkout", params: command_details.merge(text: "", trigger_id: "TOPEN")
            expect(response.parsed_body).to eq("response_type" => "ephemeral", "text" => "Opening checkout menu...")
            expect(Service::SlackConnector).to have_received(:open_modal) do |trigger, view|
              expect(trigger).to eq("TOPEN")
              expect(view[:callback_id]).to eq("checkout_modal")
              menu = view[:blocks].find { |block| block[:block_id] == "checkout_menu" }
              expect(menu.dig(:accessory, :options).map { |option| option.dig(:text, :text) }).to eq(
                ["View my checkouts", "Request a checkout", "Volunteer to do checkouts", "View open requests"])
              expect(view[:blocks].none? { |block| block[:block_id] == "checkout_shop" }).to be(true)
              expect(SlackCheckoutModal.decode_metadata(view[:private_metadata])).to include("shop_id" => shop.id.to_s)
            end
          end

          it "offers shop selection outside a configured channel" do
            post "/slack/commands/checkout", params: command_details.merge(text: "", trigger_id: "TOPEN", channel_id: "COTHER", channel_name: "general")
            expect(response.parsed_body).to include("text" => "Opening checkout menu...")
            expect(Service::SlackConnector).to have_received(:open_modal) do |_, view|
              expect(view[:blocks].any? { |block| block[:block_id] == "checkout_shop" }).to be(true)
              expect(SlackCheckoutModal.decode_metadata(view[:private_metadata])).not_to have_key("shop_id")
            end
          end

          it "returns membership guidance without opening a modal" do
            member.update!(status: "suspended")
            post "/slack/commands/checkout", params: command_details.merge(text: "", trigger_id: "TOPEN")
            expect(response.parsed_body).to eq("response_type" => "ephemeral", "text" => "Your membership is suspended. Contact the makerspace before using checkouts.")
            expect(Service::SlackConnector).not_to have_received(:open_modal)
          end
        end

        it "returns the documented acknowledgement" do
          post "/slack/commands/checkout", params: command_details, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to match(
            "response_type" => "ephemeral",
            "text" => "Looking up your active checkouts..."
          )
        end
      end

      response "403", "Slack signature is missing, invalid, or stale" do
        schema type: :object,
          properties: { error: { type: :string } },
          required: ["error"]

        it "rejects a stale signed request" do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return("documented-secret")

          post "/slack/commands/checkout",
            params: { text: "active", user_id: "U12345678" },
            headers: {
              "X-Slack-Signature" => "v0=stale",
              "X-Slack-Request-Timestamp" => 10.minutes.ago.to_i.to_s
            }

          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body).to eq("error" => "Request too old")
        end
      end
    end
  end
end
