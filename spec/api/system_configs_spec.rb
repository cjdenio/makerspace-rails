require 'swagger_helper'

RSpec.describe 'System configuration', type: :request do
  let(:member) { create(:member, :admin, :current) }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackChannelCache).to receive(:status).and_return({})
    allow(Service::AuditLogger).to receive(:log)
    allow_any_instance_of(Admin::SystemConfigsController).to receive(:slack_alert)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return(nil)
    sign_in member
  end

  path '/admin/system_configs' do
    get 'Read portal configuration (admin or board)' do
      tags 'System configuration'
      security [sessionAuth: []]
      produces 'application/json'
      response '200', 'Configuration including the effective open-ticket limit' do
        schema type: :object, required: %w[flags jobs slack volunteer totp security reservation job_schedule], properties: {
          flags: { type: :object }, jobs: { type: :array, items: { type: :object } },
          slack: { type: :object, required: %w[slack_channel_rm slack_channel_admin slack_channel_tickets], properties: {
            slack_channel_rm: { type: :string, default: 'resource_managers', description: 'Resource Managers channel. Unset or blank values use resource_managers. Membership and billing notices use slack_channel_admin instead.' },
            slack_channel_admin: { type: :string, default: 'members_relations', description: 'Members Relations channel, stored under the legacy slack_channel_admin key. Unset or blank values use members_relations.' },
            slack_channel_tickets: { type: :string, description: 'Effective ticket announcement channel. Saved override (including blank) takes precedence over SLACK_TICKETS_CHANNEL; no default channel. Blank disables central publication.' }
          } }, volunteer: { type: :object, required: ['ticket_bounty_max_credit'], properties: {
            ticket_bounty_max_credit: { type: :string, default: '2.0', description: 'Maximum credits for creating a bounty from a repair ticket. Finite number at least 0.5; changes are audited.' }
          } }, totp: { type: :object },
          reservation: { type: :object }, job_schedule: { type: :object },
          security: { type: :object, required: %w[ticket_open_limit devise_timeout_minutes], properties: {
            ticket_open_limit: { type: :integer, minimum: 1, default: 10, description: 'Maximum nonterminal reports per reporter; current admin/board reporters are exempt. Only admins can change this setting.' },
            devise_timeout_minutes: { type: :string }
          } }
        }
        run_test! { |response| expect(JSON.parse(response.body).dig('security', 'ticket_open_limit')).to eq(10) }
        context 'with default staff channels' do
          run_test! do |response|
            expect(JSON.parse(response.body).fetch('slack')).to include(
              'slack_channel_rm' => 'resource_managers', 'slack_channel_admin' => 'members_relations')
          end
        end
        context 'with independently configured staff channels' do
          before do
            SystemConfig.set('slack_channel_rm', 'CRESOURCE')
            SystemConfig.set('slack_channel_admin', 'CMEMBERS')
          end
          run_test! do |response|
            expect(JSON.parse(response.body).fetch('slack')).to include(
              'slack_channel_rm' => 'CRESOURCE', 'slack_channel_admin' => 'CMEMBERS')
          end
        end
        context 'with blank staff channel settings' do
          before do
            SystemConfig.set('slack_channel_rm', '')
            SystemConfig.set('slack_channel_admin', '')
          end
          run_test! do |response|
            expect(JSON.parse(response.body).fetch('slack')).to include(
              'slack_channel_rm' => 'resource_managers', 'slack_channel_admin' => 'members_relations')
          end
        end
        context 'without a ticket channel' do
          run_test! { |response| expect(JSON.parse(response.body).dig('slack', 'slack_channel_tickets')).to eq('') }
        end
        context 'with an environment ticket channel' do
          before { allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return('C1234567890') }
          run_test! { |response| expect(JSON.parse(response.body).dig('slack', 'slack_channel_tickets')).to eq('C1234567890') }
          context 'with a blank saved override' do
            before { SystemConfig.set('slack_channel_tickets', '') }
            run_test! { |response| expect(JSON.parse(response.body).dig('slack', 'slack_channel_tickets')).to eq('') }
          end
        end
        context 'with a configured cap' do
          before { SystemConfig.set('ticket_open_limit', '12') }
          run_test! { |response| expect(JSON.parse(response.body).dig('security', 'ticket_open_limit')).to eq(12) }
        end
      end
    end
  end

  path '/admin/system_configs/update_setting' do
    put 'Update a string setting; ticket_open_limit requires an admin and a positive integer' do
      tags 'System configuration'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :setting, in: :body, schema: {
        type: :object, required: %w[key value], properties: {
          key: { type: :string, enum: Admin::SystemConfigsController::SETTING_KEYS },
          value: { type: :string, description: 'String setting value. slack_channel_rm controls Resource Managers; slack_channel_admin controls Members Relations. Blank staff channel values use their defaults. For ticket_open_limit, use a positive integer such as "10"; zero, negatives, and fractions are rejected.' }
        },
        oneOf: [
          { properties: { key: { enum: ['ticket_open_limit'] }, value: { type: :string, pattern: '^[1-9][0-9]*$' } } },
          { properties: { key: { enum: Admin::SystemConfigsController::SETTING_KEYS - ['ticket_open_limit'] } } }
        ]
      }
      let(:setting) { { key: 'ticket_open_limit', value: '12' } }
      response '200', 'Saved setting as a string' do
        schema type: :object, required: %w[key value], properties: { key: { type: :string }, value: { type: :string } }
        context 'open ticket limit' do
          run_test! do |response|
            expect(JSON.parse(response.body)).to include('key' => 'ticket_open_limit', 'value' => '12')
            expect(SystemConfig.get('ticket_open_limit')).to eq('12')
          end
        end
        context 'ticket announcement channel override' do
          let(:setting) { { key: 'slack_channel_tickets', value: 'C9876543210' } }
          before { allow(Service::SlackChannelCache).to receive(:lookup) }
          run_test! do
            expect(SystemConfig.slack_tickets_channel).to eq('C9876543210')
            expect(Service::AuditLogger).to have_received(:log).with(hash_including(actor: member, field_changes: { 'slack_channel_tickets' => ['', 'C9876543210'] }))
          end
          context 'explicitly disabling the environment channel' do
            let(:setting) { { key: 'slack_channel_tickets', value: '  ' } }
            before { allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return('C1234567890') }
            run_test! { expect(SystemConfig.slack_tickets_channel).to eq('') }
          end
        end
        context 'ticket bounty credit maximum' do
          let(:setting) { { key: 'ticket_bounty_max_credit', value: '15' } }
          before do
            allow(Service::AuditLogger).to receive(:log).and_call_original
            allow(Service::SlackConnector).to receive(:send_slack_message)
          end
          run_test! do
            expect(SystemConfig.get('ticket_bounty_max_credit')).to eq('15')
            expect(Service::AuditLogger).to have_received(:log).with(hash_including(actor: member, field_changes: { 'ticket_bounty_max_credit' => ['', '15'] }))
            expect(AuditLog.where(event_type: 'portal_setting_changed').first.field_changes['ticket_bounty_max_credit']).to eq(['', '15'])
          end
        end
      end
      response '422', 'Invalid setting value' do
        let(:setting) { { key: 'ticket_open_limit', value: '0' } }
        run_test! { expect(SystemConfig.get('ticket_open_limit')).to be_nil }
        context 'invalid ticket bounty maximum' do
          let(:setting) { { key: 'ticket_bounty_max_credit', value: 'NaN' } }
          run_test! { expect(SystemConfig.get('ticket_bounty_max_credit')).to be_nil }
        end
      end
      response '403', 'Only admins may change ticket_open_limit' do
        let(:member) { create(:member, :current, role: 'board_member') }
        run_test! { expect(SystemConfig.get('ticket_open_limit')).to be_nil }
      end
    end
  end
end
