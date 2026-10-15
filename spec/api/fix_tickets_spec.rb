require 'swagger_helper'

RSpec.describe 'Fix tickets', type: :request do
  let(:member) { create(:member, :current) }
  let(:id) { create(:fix_ticket, reporter_id: member.id).id.to_s }
  include_context 'authenticated ticket request'
  path '/fix_tickets' do
    get 'List authorized repair tickets' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :mode, in: :query, required: false, schema: { type: :string, enum: %w[all mine assigned queue public] }
      parameter name: :statuses, in: :query, required: false, schema: { type: :array, items: { type: :string, enum: FixTicket::STATUSES } }, style: :form, explode: true
      %w[shop_id tool_id priority category confirmation assignee_id sort direction].each { |name| parameter name: name, in: :query, required: false, schema: { type: :string } }
      %w[page page_size].each { |name| parameter name: name, in: :query, required: false, schema: { type: :integer } }
      response '200', 'Scoped, filtered, sorted page; public-only readers require current membership' do
        schema '$ref' => '#/components/schemas/FixTicketPage'
        run_test!
      end
      response '401', 'A signed-in member session is required' do
        schema '$ref' => '#/components/schemas/FixError'
        before { sign_out member }
        run_test!
      end
    end
    post 'Submit a report (activeMember and future expiration; cap and catalog visibility enforced)' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :submission, in: :body, schema: {
        type: :object, required: %w[title description category submission_key], additionalProperties: false,
        properties: { title: { type: :string, maxLength: 150, pattern: FixTicket::SAFE_NAME_PATTERN }, description: { type: :string, maxLength: 10000 },
          category: { type: :string, enum: FixTicket::CATEGORIES }, submission_key: { type: :string },
          shop_id: { type: :string, nullable: true }, tool_id: { type: :string, nullable: true }, uncatalogued_tool: { type: :string, pattern: "(?:#{FixTicket::SAFE_NAME_PATTERN})|^$" },
          priority: { type: :integer, minimum: 1, maximum: 10, nullable: true }, show_identity: { type: :boolean, description: 'Show submitter identity. Defaults to true for donation_offer and false otherwise; fixed at creation.' }, i_broke_it: { type: :boolean }, i_can_fix_it: { type: :boolean }, public_read_only: { type: :boolean } }
      }
      let(:submission) { { title: 'Drill', description: 'Failed switch', category: 'broken', submission_key: SecureRandom.uuid } }
      response('200', 'Created, or previously accepted idempotent submission') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test!(requires_transactions: true) }
      response '401', 'A signed-in member session is required' do
        schema '$ref' => '#/components/schemas/FixError'
        before { sign_out member }
        run_test!
      end
      response '403', 'Reporter must be active and authorized to select the catalog resource' do
        schema '$ref' => '#/components/schemas/FixError'
        context 'inactive reporter' do
          before { member.set(expirationTime: 1.day.ago.to_i * 1000) }
          run_test!(requires_transactions: true)
        end
        context 'hidden shop selection by an active reporter' do
          let(:submission) { super().merge(shop_id: create(:shop, disabled: true).id.to_s) }
          run_test!(requires_transactions: true)
        end
        context 'hidden tool selection by an active reporter' do
          let(:shop) { create(:shop) }
          let(:submission) { super().merge(shop_id: shop.id.to_s, tool_id: create(:tool, shop: shop, disabled: true).id.to_s) }
          run_test!(requires_transactions: true)
        end
      end
      response '422', 'Malformed submission or open-ticket cap exceeded' do
        schema '$ref' => '#/components/schemas/FixError'
        context 'malformed submission' do
          let(:submission) { super().merge(title: '') }
          run_test!(requires_transactions: true)
        end
        context 'open-ticket cap exceeded' do
          let(:submission) { { title: 'Drill', description: 'Failed switch', category: 'broken', submission_key: SecureRandom.uuid } }
          before do
            allow(FixTicketService).to receive(:limit).and_return(1)
            create(:fix_ticket, reporter_id: member.id)
          end
          run_test!(requires_transactions: true) { |response| expect(response.body).to include('open tickets') }
        end
      end
      response '503', 'MongoDB topology does not support atomic ticket writes' do
        schema '$ref' => '#/components/schemas/FixError'
        before do
          allow(FixTicket).to receive(:with_session).and_raise(
            Mongo::Error::TransactionsNotSupported.new('Transactions are not supported for the cluster: standalone topology')
          )
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to include('single-node replica set', 'Transactions are not supported for the cluster: standalone topology')
          expect(FixTicket.count).to eq(0)
          expect(FixTicketEvent.count).to eq(0)
        end
      end
    end
  end
  path '/fix_tickets/catalog' do
    get 'Report catalog, creation capability, cap and current open count' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Catalog and capabilities') { schema '$ref' => '#/components/schemas/FixTicketCatalog'; run_test! }
    end
  end
  path '/fix_tickets/{id}' do
    parameter name: :id, in: :path, type: :string
    get 'Read a ticket and redacted history' do
      description 'Catalog IDs, names and availability are redacted when the viewer cannot see the referenced hidden shop/tool, including historical references. Reporter assignees appear as ordinary named assignees; assignment history never associates those names with Reporter.'
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'No reporter identity is included') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test! }
    end
    %i[patch put].each do |verb|
    public_send(verb, 'Update authorized ticket fields; priority is immutable') do
      tags 'Fix tickets'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :update, in: :body, schema: { '$ref' => '#/components/schemas/FixTicketUpdate' }
      let(:update) { { note: 'Additional details' } }
      response('200', 'Updated; operation-specific staff/assignee/reporter authorization applies') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test!(requires_transactions: true) }
      response('503', 'MongoDB topology does not support atomic ticket writes') { schema '$ref' => '#/components/schemas/FixError' }
    end
    end
  end
  { notes: ['Append a note', { respond_as: { type: :string, enum: %w[assignee reporter], description: 'Required when both reporter and assignee.' }, note: { type: :string, minLength: 2, maxLength: 10000, pattern: '\\S[\\s\\S]*\\S', description: 'Requires at least two non-whitespace characters.' } }], withdraw: ['Withdraw own nonterminal report', {}],
    assignments: ['Staff assignment or self-unassignment', { member_ids: { type: :array, items: { type: :string } }, unassign_self: { type: :boolean } }],
    bounty: ['Admin/board/relevant RM: create or replace a cancelled bounty and publish an active ticket atomically', { title: { type: :string }, description: { type: :string }, credit_value: { type: :number }, prerequisite_tool_ids: { type: :array, items: { type: :string } } }],
    reward: ['Independent authorized reviewer: approve/reject pending reporter point while the ticket remains resolved', { decision: { type: :string, enum: %w[approve reject] } }],
    reveal: ['Admin-only acknowledged reporter reveal; audit records ticket ID/title and acting admin, excluding reporter identity; no-store', { acknowledged: { type: :boolean } }],
    outage: ['Repair staff: independent tool availability', { out_of_service: { type: :boolean } }],
    retry_delivery: ['Repair staff: retry pending notifications', {}] }.each do |action, (title, properties)|
    path "/fix_tickets/{id}/#{action}" do
      parameter name: :id, in: :path, type: :string
      post title do
        tags 'Fix tickets'
        security [sessionAuth: []]
        consumes 'application/json'
        parameter name: :body, in: :body, schema: { type: :object, properties: properties, required: action == :notes ? ['note'] : [] }
        produces 'application/json'
        response '200', 'Action accepted; authorization and lifecycle validated server-side' do
          schema '$ref' => "#/components/schemas/#{ { reveal: 'FixReporterReveal', outage: 'FixOutageResult', retry_delivery: 'FixDeliveryQueued' }.fetch(action, 'FixTicketDetail') }"
          let(:member) { create(:member, :admin, :current) }
          let(:id) do
            owner = create(:member, :current)
            attributes = { title: 'Repair', description: 'Switch broken', category: 'broken', submission_key: SecureRandom.uuid }
            if action == :outage
              tool = create(:tool, shop: create(:shop))
              attributes.merge!(tool_id: tool.id.to_s, shop_id: tool.shop_id.to_s)
            end
            owner = member if action == :withdraw
            ticket = FixTicketService.create!(actor: owner, attributes: attributes)
            if action == :reward
              nominator = create(:member, :admin, :current)
              FixTicketService.update!(id: ticket.id, actor: nominator, attributes: { status: 'resolved', note: 'Fixed', nominate_reward: true })
            end
            ticket.id.to_s
          end
          let(:body) do
            case action
            when :notes then { note: 'Further details' }
            when :assignments then { member_ids: [member.id.to_s] }
            when :bounty then { title: 'Repair drill', description: 'Replace switch', credit_value: 1 }
            when :reward then { decision: 'reject' }
            when :reveal then { acknowledged: true }
            when :outage then { out_of_service: true }
            else {}
            end
          end
          run_test!(requires_transactions: true)
        end
        response '403', 'Caller lacks this action capability; reporters cannot publish their own bounty' do
          schema '$ref' => '#/components/schemas/FixError'
          if action == :bounty
            let(:body) { { title: 'Repair', description: 'Fix switch', credit_value: 1 } }
            %w[admin board_member resource_manager].each do |role|
              context "reporter with #{role} privileges" do
                let(:shop) { create(:shop) }
                let(:member) { create(:member, :current, role: role, resource_manager_shop_ids: [shop.id.to_s]) }
                let(:id) { create(:fix_ticket, reporter_id: member.id, shop_id: shop.id).id.to_s }
                run_test!(requires_transactions: true) do
                  expect(FixTicket.find(id).bounty_id).to be_nil
                  expect(VolunteerTask.count).to eq(0)
                  expect(FixTicketPolicy.new(member, FixTicket.find(id)).capabilities[:canCreateBounty]).to be(false)
                end
              end
            end
          end
        end
        response '422', 'Validation, cap, revision, or lifecycle conflict' do
          schema '$ref' => '#/components/schemas/FixError'
          if action == :reward
            let(:member) { create(:member, :admin, :current) }
            let(:body) { { decision: 'approve' } }
            let(:id) do
              ticket = create(:fix_ticket)
              credit = VolunteerCredit.create!(member_id: ticket.reporter_id, issued_by_id: create(:member, :admin, :current).id,
                ticket_id: ticket.id, description: 'Helpful report', credit_value: 1, status: 'pending')
              ticket.set(reward_id: credit.id)
              ticket.id.to_s
            end
            run_test!(requires_transactions: true) do |response|
              expect(response.body).to include('must be resolved')
              expect(VolunteerCredit.find(FixTicket.find(id).reward_id).status).to eq('pending')
            end
          end
          if action == :notes
            let(:body) { { note: ' a ' } }
            run_test!(requires_transactions: true)
          end
        end
        unless %i[reveal outage retry_delivery].include?(action)
          response('503', 'MongoDB topology does not support atomic ticket writes') { schema '$ref' => '#/components/schemas/FixError' }
        end
        if action == :reveal
          response '503', 'Identity is withheld when the reveal audit cannot be saved' do
            schema '$ref' => '#/components/schemas/FixError'
            let(:member) { create(:member, :admin, :current) }
            let(:body) { { acknowledged: true } }
            before { allow(Service::AuditLogger).to receive(:log).and_return(nil) }
            run_test!(requires_transactions: true) do |response|
              expect(JSON.parse(response.body)).not_to have_key('name')
              expect(JSON.parse(response.body)).not_to have_key('id')
            end
          end
        end
      end
    end
  end
  path '/fix_tickets/{id}/assignee_options' do
    parameter name: :id, in: :path, type: :string
    get 'Repair staff: search eligible assignees' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      parameter name: :search, in: :query, required: false, type: :string
      produces 'application/json'
      response '403', 'Ticket readers who are not repair staff cannot list assignee options' do
        schema '$ref' => '#/components/schemas/FixError'
        run_test!
        context 'assigned member' do
          let(:id) { create(:fix_ticket, reporter_id: create(:member, :current).id, assignee_ids: [member.id]).id.to_s }
          run_test!
        end
      end
      response('200', 'Up to fifty active unexpired members') { schema type: :array, items: { '$ref' => '#/components/schemas/FixPerson' }; let(:member) { create(:member, :admin, :current) }; run_test! }
    end
  end
  path '/tools/{id}/outage' do
    parameter name: :id, in: :path, type: :string
    post 'Repair staff: change out-of-service independently of hidden' do
      tags 'Tools'
      security [sessionAuth: []]
      consumes 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['out_of_service'], properties: { out_of_service: { type: :boolean } } }
      produces 'application/json'
      response('200', 'Availability and affected reservations for review') do
        schema '$ref' => '#/components/schemas/FixOutageResult'
        let(:member) { create(:member, :admin, :current) }
        let(:id) { create(:tool, shop: create(:shop)).id.to_s }
        let(:body) { { out_of_service: true } }
        run_test!
      end
    end
  end
  path '/volunteer/tasks/{id}/detail' do
    parameter name: :id, in: :path, type: :string
    get 'Authenticated bounty detail including optional source ticket_id' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      response '401', 'A signed-in member session is required' do
        schema '$ref' => '#/components/schemas/FixError'
        before { sign_out member }
        run_test!
      end
      response '422', 'Malformed task ID' do
        schema '$ref' => '#/components/schemas/FixError'
        let(:id) { 'malformed' }
        run_test!
      end
      response '404', 'Task does not exist' do
        schema '$ref' => '#/components/schemas/FixError'
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
      response '403', 'Non-current members must be authorized to read the source ticket' do
        schema '$ref' => '#/components/schemas/FixError'
        let(:id) do
          ticket = create(:fix_ticket, reporter_id: create(:member, :current).id)
          VolunteerTask.create!(title: 'Repair', description: 'Fix switch', created_by_id: ticket.reporter_id, ticket_id: ticket.id).id.to_s
        end
        before { member.set(expirationTime: 1.day.ago.to_i * 1000) }
        run_test!
      end
      response('200', 'Current member or authorized source-ticket viewer') do
        schema '$ref' => '#/components/schemas/FixBountyDetail'
        let(:id) { VolunteerTask.create!(title: 'Repair drill', description: 'Replace switch', credit_value: 1, created_by_id: member.id).id.to_s }
        run_test!
      end
    end
  end
  path '/admin/volunteer_tasks/{id}/cancel' do
    parameter name: :id, in: :path, type: :string
    post 'Cancel a volunteer task; linked claims must first be released or rejected' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      response '403', 'A claimed or pending ticket bounty must be released or rejected before cancellation' do
        let(:member) { create(:member, :admin, :current) }
        let(:id) do
          ticket = FixTicketService.create!(actor: create(:member, :current), attributes: { title: 'Repair', description: 'Broken', category: 'broken', submission_key: SecureRandom.uuid })
          FixTicketService.bounty!(id: ticket.id, actor: member, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
          task = ticket.reload.bounty
          task.update!(status: 'claimed', claimed_by_id: member.id)
          task.id.to_s
        end
        before do
          allow_any_instance_of(Admin::VolunteerTasksController).to receive(:slack_alert)
          allow_any_instance_of(Admin::VolunteerTasksController).to receive(:honeybadger_notify)
        end
        run_test!(requires_transactions: true)
      end
    end
  end
  path '/slack/commands/fix' do
    post 'Open Fix tickets; Slack signature, workspace and linked member required', operation: { servers: [{ url: '/' }] } do
      description 'Handles /fix and /fix-tickets. new prefills a matching shop channel; other lists default to that shop filter. show returns an ephemeral, paginated list of all authorized open tickets (including public and approver scope), prefixed Tickets in SHOP NAME: in a shop channel. Ticket numbers accept an optional # prefix. Modal input blocks include persistent labels and hints.'
      tags 'Slack'
      consumes 'application/x-www-form-urlencoded'
      produces 'application/json'
      parameter name: :'X-Slack-Request-Timestamp', in: :header, required: true, schema: { type: :string }
      parameter name: :'X-Slack-Signature', in: :header, required: true, schema: { type: :string }
      parameter name: :payload, in: :body, required: true, schema: { type: :object,
        required: %w[team_id user_id trigger_id], properties: { text: { type: :string }, command: { type: :string, enum: ['/fix', '/fix-tickets'] }, channel_id: { type: :string }, channel_name: { type: :string }, team_id: { type: :string }, user_id: { type: :string }, trigger_id: { type: :string } } }
      response('200', 'Private response; opens an authorized modal') do
        schema type: :object, properties: { response_type: { type: :string, enum: ['ephemeral'] }, text: { type: :string }, blocks: { type: :array, items: { type: :object }, description: 'Private show results with ticket numbers and pagination actions.' } }, required: %w[response_type text]
        let(:'X-Slack-Request-Timestamp') { Time.now.to_i.to_s }
        let(:'X-Slack-Signature') { 'signature-tested-in-slack-request-specs' }
        let(:team_id) { 'T_TEST' }
        let(:user_id) { 'U_TEST' }
        let(:trigger_id) { 'trigger' }
        before do
          allow_any_instance_of(Slack::FixController).to receive(:verify_slack_signature)
          allow(FixSlack).to receive(:member!).and_return(member)
          allow(Service::SlackConnector).to receive(:open_modal)
        end
        it 'returns an ephemeral response from the root Slack route' do |example|
          post '/slack/commands/fix', params: { team_id: team_id, user_id: user_id, trigger_id: trigger_id }
          assert_response_matches_metadata(example.metadata)
        end
        it 'returns show results privately without opening a modal' do |example|
          shop = create(:shop, name: 'Woodworking', slack_channel: 'woodworking')
          ticket = create(:fix_ticket, reporter_id: member.id, shop_id: shop.id)
          post '/slack/commands/fix', params: { command: '/fix-tickets', text: 'show', team_id: team_id, user_id: user_id, trigger_id: trigger_id, channel_id: 'C_WOOD', channel_name: 'woodworking' }
          assert_response_matches_metadata(example.metadata)
          expect(JSON.parse(response.body)['text']).to start_with('Tickets in Woodworking:')
          expect(response.body).to include("##{ticket.id}:")
          expect(Service::SlackConnector).not_to have_received(:open_modal)
        end
      end
    end
  end
end
