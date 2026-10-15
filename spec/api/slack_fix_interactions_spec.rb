require 'swagger_helper'

RSpec.describe 'Signed Fix interactions', type: :request do
  let(:member) { create(:member, :current) }
  let(:secret) { 'isolated-interaction-test-secret' }
  let(:identity) { { team: { id: 'T_TEST' }, user: { id: 'U_TEST' } } }
  before do
    # Fixture creation must not provision Slack users, even when invites are enabled.
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
    allow(FixSlack).to receive(:member!).and_return(member)
    allow(Service::SlackConnector).to receive(:client).and_return(double(views_update: {}))
  end
  def send_interaction(payload, valid: true)
    body = URI.encode_www_form(payload: payload.to_json)
    timestamp = Time.now.to_i.to_s
    signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
    post '/slack/interactions', params: body, headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
      'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => valid ? signature : 'invalid' }
  end
  path '/slack/interactions' do
    post 'Signed Slack interactions including Fix suggestions, buttons, and modal submissions', operation: { servers: [{ url: '/' }] } do
      tags 'Slack'
      security []
      consumes 'application/x-www-form-urlencoded'
      produces 'application/json'
      description 'Requires a valid Slack HMAC signature and timestamp within five minutes. Fix interactions also validate workspace and linked member, then recheck action permissions. payload is a JSON-encoded FixSlackInteractionPayload. Assignee-filter suggestions are restricted to members assigned to tickets the caller can view; staff assignment searches still require ticket management rights and current candidate membership. Suggestions return options; buttons acknowledge with {} and update the Slack view; modal submissions return update/view or errors keyed by block ID. Existing non-Fix interactions remain supported.'
      parameter name: :'X-Slack-Request-Timestamp', in: :header, required: true, schema: { type: :string }
      parameter name: :'X-Slack-Signature', in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: ['payload'], properties: {
        payload: { type: :string, description: 'JSON encoding of #/components/schemas/FixSlackInteractionPayload', example: '{"type":"block_suggestion","action_id":"fix_search_shop_id","value":"Wood","team":{"id":"T123"},"user":{"id":"U123"}}' } } }
      response('200', 'Options, acknowledgment, updated modal, or block validation errors') do
        schema '$ref' => '#/components/schemas/FixSlackInteractionResponse'
        it 'restricts assignee filter suggestions to the caller\'s visible tickets' do |example|
          assignee = create(:member, :current)
          create(:member, :current, firstname: 'Unrelated')
          create(:fix_ticket, reporter_id: member.id, assignee_ids: [assignee.id])
          send_interaction(identity.merge(type: 'block_suggestion', action_id: 'fix_search_assignee_id', value: ''))
          assert_response_matches_metadata(example.metadata)
          expect(JSON.parse(response.body)['options'].map { |option| option['value'] }).to eq([assignee.id.to_s])
        end
        {
          suggestions: { type: 'block_suggestion', action_id: 'fix_search_shop_id', value: '' },
          button: { type: 'block_actions', actions: [{ action_id: 'fix_filters', value: '{"mode":"mine"}' }], view: { id: 'V_TEST' } },
          update: { type: 'view_submission', view: { callback_id: 'fix_filters', private_metadata: '{}', state: { values: {} } } },
          errors: { type: 'view_submission', view: { callback_id: 'fix_note', private_metadata: '{}', state: { values: { note: { note: { value: 'x' } } } } } }
        }.each do |kind, payload|
          it "returns #{kind} for the signed Fix payload" do |example|
            send_interaction(identity.merge(payload))
            assert_response_matches_metadata(example.metadata)
            data = JSON.parse(response.body)
            case kind
            when :suggestions then expect(data).to have_key('options')
            when :button then expect(data).to eq({})
            else expect(data['response_action']).to eq(kind.to_s)
            end
          end
        end
      end
      response('403', 'Invalid/missing signature, expired timestamp, or missing signing secret') do
        schema type: :object, properties: { error: { type: :string } }, required: ['error']
        it 'rejects unsigned interaction payloads' do |example|
          send_interaction(identity.merge(type: 'block_suggestion', action_id: 'fix_search_shop_id'), valid: false)
          assert_response_matches_metadata(example.metadata)
          expect(FixSlack).not_to have_received(:member!)
        end
      end
    end
  end
end
