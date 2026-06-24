require 'rails_helper'

RSpec.describe Admin::AuditLogsController, type: :controller do
  set_devise_mapping

  let(:admin)  { create(:member, role: 'admin') }
  let(:board)  { create(:member, role: 'board_member') }
  let(:rm)     { create(:member, role: 'resource_manager') }
  let(:member) { create(:member) }

  let!(:log1) do
    log = AuditLog.create!(
      log_type:      'member',
      event_type:    'member_updated',
      resource_type: 'Member',
      resource_id:   member.id,
      actor_id:      admin.id,
      actor_name:    admin.fullname,
      subject_id:    member.id,
      subject_name:  member.fullname,
      slack_message: 'Member Updated by Admin on Jane Smith\'s Member'
    )
    log.set(created_at: 2.days.ago)
    log.reload
  end

  let!(:log2) do
    log = AuditLog.create!(
      log_type:      'portal',
      event_type:    'portal_setting_changed',
      resource_type: 'SystemConfig',
      resource_id:   BSON::ObjectId.new,
      actor_id:      board.id,
      actor_name:    board.fullname,
      slack_message: 'Portal Setting Changed by Board on SystemConfig'
    )
    log.set(created_at: 1.day.ago)
    log.reload
  end

  describe 'GET #index' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns all logs' do
        get :index, format: :json
        expect(response).to have_http_status(:ok)
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(2)
      end

      it 'filters by log_type' do
        get :index, params: { log_type: 'portal' }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['eventType']).to eq('portal_setting_changed')
      end

      it 'filters by event_type' do
        get :index, params: { event_type: 'member_updated' }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['logType']).to eq('member')
      end

      it 'filters by actor_id' do
        get :index, params: { actor_id: admin.id.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['actorName']).to eq(admin.fullname)
      end

      it 'filters by subject_id' do
        get :index, params: { subject_id: member.id.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
      end

      it 'filters by from_date' do
        get :index, params: { from_date: 1.5.days.ago.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['eventType']).to eq('portal_setting_changed')
      end

      it 'returns logs ordered newest first' do
        get :index, format: :json
        parsed = JSON.parse(response.body)
        dates = parsed.map { |l| Time.parse(l['createdAt']) }
        expect(dates).to eq(dates.sort.reverse)
      end
    end

    context 'as board member' do
      before { sign_in board }

      it 'is permitted' do
        get :index, format: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context 'as resource manager' do
      before { sign_in rm }

      it 'is forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'as regular member' do
      before { sign_in member }

      it 'is forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
