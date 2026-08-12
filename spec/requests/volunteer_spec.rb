require 'rails_helper'

RSpec.describe 'Volunteer endpoints', type: :request do
  let(:active_member)   { create(:member, status: 'activeMember') }
  let(:inactive_member) { create(:member, status: 'inactive') }
  let(:admin)           { create(:member, :admin) }

  let(:task_attrs) do
    {
      title:         'Clean up woodshop',
      description:   'Sweep and organize the lumber rack',
      credit_value:  1.0,
      created_by_id: admin.id,
      status:        'available'
    }
  end

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(SlackUser).to receive(:find_by).and_return(nil)
  end

  # ── GET /api/volunteer/tasks ─────────────────────────────────────────────

  describe 'GET /api/volunteer/tasks' do
    before { sign_in active_member }

    it 'returns claimable parent tasks only' do
      available  = VolunteerTask.create!(task_attrs.merge(status: 'available'))
      reusable   = VolunteerTask.create!(task_attrs.merge(status: 'reusable', title: 'Reusable'))
      repeatable = VolunteerTask.create!(task_attrs.merge(status: 'repeatable', title: 'Repeatable'))
      recurring  = VolunteerTask.create!(task_attrs.merge(status: 'recurring', title: 'Recurring', days: 7))
      cooling    = VolunteerTask.create!(task_attrs.merge(status: 'recurring', title: 'Cooling', days: 7, next_available: Date.tomorrow))
      child      = VolunteerTask.create!(task_attrs.merge(status: 'claimed', parent_task_id: reusable.id, claimed_by_id: active_member.id))

      get '/api/volunteer/tasks'

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).map { |t| t['id'] }
      expect(ids).to include(available.id.to_s, reusable.id.to_s, repeatable.id.to_s, recurring.id.to_s)
      expect(ids).not_to include(cooling.id.to_s)
      expect(ids).not_to include(child.id.to_s)
    end
  end

  # ── GET /api/volunteer/tasks/my_claims ───────────────────────────────────

  describe 'GET /api/volunteer/tasks/my_claims' do
    before { sign_in active_member }

    it 'returns standard claimed tasks' do
      task = VolunteerTask.create!(task_attrs.merge(status: 'claimed', claimed_by_id: active_member.id))
      get '/api/volunteer/tasks/my_claims'
      ids = JSON.parse(response.body).map { |t| t['id'] }
      expect(ids).to include(task.id.to_s)
    end

    it 'returns child task claims from multi-use parents' do
      parent = VolunteerTask.create!(task_attrs.merge(status: 'reusable'))
      child  = VolunteerTask.create!(task_attrs.merge(
        status: 'claimed', parent_task_id: parent.id, claimed_by_id: active_member.id
      ))
      get '/api/volunteer/tasks/my_claims'
      ids = JSON.parse(response.body).map { |t| t['id'] }
      expect(ids).to include(child.id.to_s)
    end

    it 'does not return completed or denied claims' do
      done   = VolunteerTask.create!(task_attrs.merge(status: 'completed', claimed_by_id: active_member.id))
      denied = VolunteerTask.create!(task_attrs.merge(status: 'denied', claimed_by_id: active_member.id))
      get '/api/volunteer/tasks/my_claims'
      ids = JSON.parse(response.body).map { |t| t['id'] }
      expect(ids).not_to include(done.id.to_s, denied.id.to_s)
    end
  end

  # ── POST /api/volunteer/tasks/:id/claim ──────────────────────────────────

  describe 'POST /api/volunteer/tasks/:id/claim' do
    context 'when member is active' do
      before { sign_in active_member }

      it 'claims a standard available task' do
        task = VolunteerTask.create!(task_attrs)
        post "/api/volunteer/tasks/#{task.id}/claim"
        expect(response).to have_http_status(:ok)
        expect(task.reload.status).to eq('claimed')
      end

      it 'creates a child document for a reusable task' do
        task = VolunteerTask.create!(task_attrs.merge(status: 'reusable'))
        expect {
          post "/api/volunteer/tasks/#{task.id}/claim"
        }.to change { VolunteerTask.count }.by(1)
        expect(task.reload.status).to eq('reusable')
      end

      it 'returns 422 when trying to claim a reusable task twice' do
        task = VolunteerTask.create!(task_attrs.merge(status: 'reusable'))
        post "/api/volunteer/tasks/#{task.id}/claim"
        post "/api/volunteer/tasks/#{task.id}/claim"
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)['error']).to match(/already claimed/i)
      end

      it 'returns 422 when a recurring task is cooling down' do
        task = VolunteerTask.create!(task_attrs.merge(
          status: 'recurring', days: 7, next_available: Date.tomorrow
        ))
        post "/api/volunteer/tasks/#{task.id}/claim"
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)['error']).to match(/not yet available/i)
      end
    end

    context 'when member is not active' do
      before { sign_in inactive_member }

      it 'returns 403 for inactive member' do
        task = VolunteerTask.create!(task_attrs)
        post "/api/volunteer/tasks/#{task.id}/claim"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # ── POST /api/volunteer/tasks/:id/complete ───────────────────────────────

  describe 'POST /api/volunteer/tasks/:id/complete' do
    before { sign_in active_member }

    it 'moves a claimed task to pending' do
      task = VolunteerTask.create!(task_attrs.merge(status: 'claimed', claimed_by_id: active_member.id))
      post "/api/volunteer/tasks/#{task.id}/complete"
      expect(response).to have_http_status(:ok)
      expect(task.reload.status).to eq('pending')
    end

    it 'returns 422 if member does not own the task' do
      other = create(:member)
      task  = VolunteerTask.create!(task_attrs.merge(status: 'claimed', claimed_by_id: other.id))
      post "/api/volunteer/tasks/#{task.id}/complete"
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # ── POST /api/volunteer/events/:id/checkin ───────────────────────────────

  describe 'POST /api/volunteer/events/:id/checkin' do
    let(:event) { VolunteerEvent.create!(title: 'Cleanup day', description: 'Help clean up', credit_value: 1.0, created_by_id: admin.id) }

    it 'checks in an active member' do
      sign_in active_member
      post "/api/volunteer/events/#{event.id}/checkin"
      expect(response).to have_http_status(:ok)
      expect(event.reload.attendee_ids).to include(active_member.id)
    end

    it 'returns 403 for an inactive member' do
      sign_in inactive_member
      post "/api/volunteer/events/#{event.id}/checkin"
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 422 if already checked in' do
      sign_in active_member
      post "/api/volunteer/events/#{event.id}/checkin"
      post "/api/volunteer/events/#{event.id}/checkin"
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end

RSpec.describe 'Admin Volunteer Tasks endpoints', type: :request do
  let(:admin)  { create(:member, :admin) }
  let(:member) { create(:member, status: 'activeMember') }

  let(:task_attrs) do
    {
      title: 'Fix shelving', description: 'Repair the wood shelf',
      credit_value: 1.0, created_by_id: admin.id, status: 'available'
    }
  end

  before do
    sign_in admin
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(SlackUser).to receive(:find_by).and_return(nil)
  end

  describe 'POST /api/admin/volunteer_tasks/:id/release' do
    it 'returns 422 without a reason (correct error class)' do
      task = VolunteerTask.create!(task_attrs.merge(status: 'claimed', claimed_by_id: member.id))
      post "/api/admin/volunteer_tasks/#{task.id}/release"
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'releases a claimed task with a reason' do
      task = VolunteerTask.create!(task_attrs.merge(status: 'claimed', claimed_by_id: member.id))
      post "/api/admin/volunteer_tasks/#{task.id}/release", params: { reason: 'No response' }
      expect(response).to have_http_status(:ok)
      expect(task.reload.status).to eq('available')
    end

    it 'sets child task to denied instead of available' do
      parent = VolunteerTask.create!(task_attrs.merge(status: 'reusable'))
      child  = VolunteerTask.create!(task_attrs.merge(
        status: 'claimed', claimed_by_id: member.id, parent_task_id: parent.id
      ))
      post "/api/admin/volunteer_tasks/#{child.id}/release", params: { reason: 'Abandoned' }
      expect(child.reload.status).to eq('denied')
    end
  end

  describe 'POST /api/admin/volunteer_tasks/:id/complete' do
    it 'returns 403 when claimant is not an active member' do
      inactive = create(:member, status: 'inactive')
      task = VolunteerTask.create!(task_attrs.merge(status: 'pending', claimed_by_id: inactive.id))
      post "/api/admin/volunteer_tasks/#{task.id}/complete"
      expect(response).to have_http_status(:forbidden)
    end

    it 'completes a pending task and issues a credit' do
      task = VolunteerTask.create!(task_attrs.merge(status: 'pending', claimed_by_id: member.id))
      expect {
        post "/api/admin/volunteer_tasks/#{task.id}/complete"
      }.to change { VolunteerCredit.count }.by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /api/admin/volunteer_tasks/:id/reset_cooldown' do
    it 'clears next_available on a recurring task' do
      task = VolunteerTask.create!(task_attrs.merge(
        status: 'recurring', days: 7, next_available: Date.tomorrow
      ))
      post "/api/admin/volunteer_tasks/#{task.id}/reset_cooldown"
      expect(response).to have_http_status(:ok)
      expect(task.reload.next_available).to be_nil
    end

    it 'returns 422 for non-recurring tasks' do
      task = VolunteerTask.create!(task_attrs)
      post "/api/admin/volunteer_tasks/#{task.id}/reset_cooldown"
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end

RSpec.describe 'Admin Volunteer Credits endpoints', type: :request do
  let(:admin)    { create(:member, :admin) }
  let(:active)   { create(:member, status: 'activeMember') }
  let(:inactive) { create(:member, status: 'inactive') }

  before do
    sign_in admin
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(SlackUser).to receive(:find_by).and_return(nil)
  end

  describe 'POST /api/admin/volunteer_credits' do
    it 'awards a credit to an active member as pending, with the given credit value' do
      post '/api/admin/volunteer_credits',
           params: { member_id: active.id.to_s, description: 'Helped with cleanup', credit_value: 2.5 }
      expect(response).to have_http_status(:ok)
      expect(VolunteerCredit.where(member_id: active.id).count).to eq(1)

      credit = VolunteerCredit.find_by(member_id: active.id)
      expect(credit.status).to eq('pending')
      expect(credit.credit_value).to eq(2.5)
    end

    it 'returns 403 when awarding to a non-active member' do
      post '/api/admin/volunteer_credits',
           params: { member_id: inactive.id.to_s, description: 'Test', credit_value: 1 }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['error']).to match(/not an active member/i)
    end

    it 'returns 422 when credit_value is missing or not positive' do
      post '/api/admin/volunteer_credits',
           params: { member_id: active.id.to_s, description: 'Test' }
      expect(response).to have_http_status(:unprocessable_content)

      post '/api/admin/volunteer_credits',
           params: { member_id: active.id.to_s, description: 'Test', credit_value: 0 }
      expect(response).to have_http_status(:unprocessable_content)

      post '/api/admin/volunteer_credits',
           params: { member_id: active.id.to_s, description: 'Test', credit_value: -1 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when description is blank' do
      post '/api/admin/volunteer_credits',
           params: { member_id: active.id.to_s, description: '', credit_value: 1 }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
