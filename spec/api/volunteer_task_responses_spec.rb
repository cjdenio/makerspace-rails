require 'swagger_helper'

RSpec.describe 'Generic volunteer task responses', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:claimant) { create(:member, :current) }
  let(:ticket_id) { create(:fix_ticket, reporter_id: claimant.id).id }
  let(:task) { VolunteerTask.create!(title: 'Repair', description: 'Replace switch', created_by_id: member.id, ticket_id: ticket_id) }
  let(:id) { task.id.to_s }
  before do
    sign_in member
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow_any_instance_of(VolunteerTask).to receive(:notify_task_verified)
    allow_any_instance_of(VolunteerTask).to receive(:notify_member_task_released)
    allow_any_instance_of(VolunteerTask).to receive(:notify_member_task_rejected)
    allow_any_instance_of(VolunteerCredit).to receive(:notify_member_credit_awarded)
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
  end

  %w[/volunteer/tasks /volunteer/tasks/my_claims /admin/volunteer_tasks].each do |endpoint|
    path endpoint do
      get 'List volunteer tasks including nullable source ticketId' do
        tags 'Volunteer'
        security [sessionAuth: []]
        produces 'application/json'
        if endpoint == '/admin/volunteer_tasks'
          %w[status parent_task_id].each { |key| parameter name: key, in: :query, required: false, schema: { type: :string } }
          %w[parents_only children_only].each { |key| parameter name: key, in: :query, required: false, schema: { type: :boolean } }
        end
        response '200', 'Task array; ticketId identifies the independently authorized source ticket' do
          schema type: :array, items: { '$ref' => '#/components/schemas/VolunteerTask' }
          before do
            task
            task.update!(status: 'claimed', claimed_by_id: member.id) if endpoint.end_with?('my_claims')
          end
          run_test! do |response|
            expect(JSON.parse(response.body)).to include(
              hash_including('id' => task.id.to_s, 'ticketId' => ticket_id.to_s)
            )
          end
        end
      end
    end
  end

  [['/admin/volunteer_tasks', :post], ['/admin/volunteer_tasks/{id}', :put], ['/admin/volunteer_tasks/{id}', :patch]].each do |endpoint, verb|
    path endpoint do
      parameter name: :id, in: :path, type: :string unless verb == :post
      public_send(verb, 'Save a volunteer task') do
        tags 'Volunteer'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/VolunteerTaskWrite' }
        let(:body) { { title: 'Repair', description: 'Replace switch', credit_value: 1 } }
        unless verb == :post
          response '403', 'Only admin and board may change linked bounty credits' do
            schema '$ref' => '#/components/schemas/FixError'
            let(:shop) { create(:shop) }
            let(:member) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
            let(:body) { { credit_value: 1000 } }
            before { task.set(shop_id: shop.id) }
            run_test! { expect(task.reload.credit_value).to eq(1) }
          end
        end
        response '200', 'Saved task with nullable ticketId (source linkage is not generically editable)' do
          schema '$ref' => '#/components/schemas/VolunteerTask'
          run_test! { |response| expect(JSON.parse(response.body)).to have_key('ticketId') }
          unless verb == :post
            %w[admin board_member].each do |role|
              context "uncapped credit edit by #{role}" do
                let(:member) { create(:member, :current, role: role) }
                let(:body) { { credit_value: 1000.5 } }
                run_test! do
                  expect(task.reload.credit_value).to eq(1000.5)
                  audit = AuditLog.where(event_type: 'volunteer_task_credit_changed', resource_id: task.id).first
                  expect(audit.actor_id).to eq(member.id)
                  expect(audit.field_changes['credit_value']).to eq([1.0, 1000.5])
                end
              end
            end
          end
        end
      end
    end
  end

  { '/volunteer/tasks/{id}/claim' => 'available', '/volunteer/tasks/{id}/complete' => 'claimed',
    '/admin/volunteer_tasks/{id}/complete' => 'pending', '/admin/volunteer_tasks/{id}/release' => 'claimed',
    '/admin/volunteer_tasks/{id}/reject_pending' => 'pending', '/admin/volunteer_tasks/{id}/cancel' => 'available',
    '/admin/volunteer_tasks/{id}/reset_cooldown' => 'recurring' }.each do |endpoint, state|
    path endpoint do
      parameter name: :id, in: :path, type: :string
      post 'Apply authorized volunteer task lifecycle action' do
        tags 'Volunteer'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { type: :object, properties: { reason: { type: :string } } }
        let(:body) { { reason: 'Unable to finish' } }
        # Generic tasks run on standalone MongoDB too; linked lifecycle behavior
        # is covered separately by transaction-tagged service specs.
        let(:ticket_id) { nil }
        before { task.update!(status: state, days: state == 'recurring' ? 7 : nil, claimed_by_id: endpoint == '/volunteer/tasks/{id}/complete' ? member.id : claimant.id) }
        response '200', 'Task after action, including nullable ticketId' do
          schema '$ref' => '#/components/schemas/VolunteerTask'
          run_test! { |response| expect(JSON.parse(response.body)).to have_key('ticketId') }
        end
        if endpoint == '/volunteer/tasks/{id}/claim'
          response '422', 'Task is no longer available to claim' do
            schema '$ref' => '#/components/schemas/FixError'
            before { task.set(status: 'claimed', claimed_by_id: claimant.id) }
            run_test!
          end
          response '403', 'Ineligible claimant, including the reporter of a linked repair ticket' do
            schema '$ref' => '#/components/schemas/FixError'
            let(:ticket_id) { FixTicket.create!(reporter_id: member.id, title: 'Broken', description: 'Switch failed', category: 'broken', submission_key: SecureRandom.uuid).id }
            run_test! do
              expect(task.reload.status).to eq('available')
              expect(FixTicket.find(ticket_id).assignee_ids).to be_empty
            end
          end
        end
      end
    end
  end
  path '/admin/volunteer_tasks/{id}' do
    parameter name: :id, in: :path, type: :string
    delete 'Delete an unlinked volunteer task' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      response '422', 'Linked bounties must be cancelled to preserve ticket history' do
        schema '$ref' => '#/components/schemas/FixError'
        run_test! do |response|
          expect(response.body).to include('Cancel linked bounties')
          expect(VolunteerTask.where(id: task.id)).to exist
        end
      end
      response '204', 'Unlinked task deleted' do
        let(:ticket_id) { nil }
        run_test! { expect(VolunteerTask.where(id: id)).not_to exist }
      end
      response '503', 'Slack reminder finalization unavailable; cancelled task retained for retry' do
        schema type: :object, required: %w[status error message], properties: {
          status: { type: :integer, enum: [503] },
          error: { type: :string, enum: ['service_unavailable'] },
          message: { type: :string }
        }
        let(:ticket_id) { nil }
        before do
          completed_at = 6.days.ago
          task.set(status: 'pending', claimed_by_id: claimant.id, completed_at: completed_at,
            approval_notification: {
              'ts' => '123.456', 'channel' => 'CREVIEW', 'destination_mode' => 'production',
              'started_at' => completed_at.to_time.getutc, 'subject' => 'Task pending review', 'finalized' => true
            })
          allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
          allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')
          allow(Service::ErrorReporter).to receive(:notify)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)).to include('status' => 503, 'error' => 'service_unavailable',
            'message' => 'Cannot delete task until its Slack reminders have been finalized; retry deletion after delivery recovers')
          expect(task.reload.status).to eq('cancelled')
          expect(task.approval_notification).to include('ts' => '123.456', 'finalized' => false)
          expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask).where(id: task.id)).to exist

          allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
          delete "/api/admin/volunteer_tasks/#{id}"
          expect(self.response).to have_http_status(:no_content)
          expect(VolunteerTask.where(id: id)).not_to exist
        end
      end
    end
  end

end
