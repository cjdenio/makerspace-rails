require 'rails_helper'

RSpec.describe Admin::TemplatesController, type: :controller do
  set_devise_mapping

  let(:admin) { create(:member, role: 'admin') }
  let(:board_member) { create(:member, :board_member) }
  let(:template_status) do
    {
      name: 'reservation_reminder',
      env_key: 'DOC_RESERVATION_REMINDER_ID',
      status: 'ok',
      fetched_at: Time.current.iso8601
    }
  end

  before do
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::EmailTemplate).to receive(:status).and_return(template_status)
  end

  it 'lists templates for an administrator' do
    sign_in admin
    allow(Service::EmailTemplate).to receive(:statuses).and_return([template_status])

    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('templates', 0, 'env_key')).to eq('DOC_RESERVATION_REMINDER_ID')
  end

  it 'rejects a board member because the tab is admin-only' do
    sign_in board_member

    get :index, format: :json

    expect(response).to have_http_status(:forbidden)
  end

  it 'refreshes one template and writes an audit entry' do
    sign_in admin
    allow(Service::EmailTemplate).to receive(:refresh!).with(:reservation_reminder)

    post :refresh, params: { id: 'reservation_reminder' }, format: :json

    expect(response).to have_http_status(:ok)
    expect(Service::EmailTemplate).to have_received(:refresh!).with(:reservation_reminder)
    expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'template_refresh'))
  end

  it 'surfaces Google permission errors' do
    sign_in admin
    allow(Service::EmailTemplate).to receive(:restore_default!)
      .and_raise(Service::EmailTemplate::PermissionError, 'writer access required')

    post :restore, params: { id: 'reservation_reminder' }, format: :json

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['error']).to include('writer access required')
    expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'template_action_failed'))
  end

  it 'reports and audits wrapped template refresh failures' do
    sign_in admin
    allow(Service::EmailTemplate).to receive(:refresh!)
      .and_raise(Service::EmailTemplate::TemplateError, 'connection reset')

    post :refresh, params: { id: 'reservation_reminder' }, format: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to eq('connection reset')
    expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'template_action_failed'))
  end
end
