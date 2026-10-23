require 'rails_helper'

RSpec.describe Admin::AnalyticsController, type: :controller do
  set_devise_mapping
  let(:admin) { create(:member, :admin) }

  before do
    sign_in admin
    allow(Service::Analytics::Members).to receive(:summary_counts).and_return(
      total_members: 10, new_members: 2, lost_members: 1, subscribed_members: 7
    )
    allow(Service::Analytics::Invoices).to receive(:summary_counts).and_return(
      past_due_invoices: 1, refunds_pending: 3
    )
    allow(Service::CardExpirationCheck).to receive(:expiring_member_count).and_return(4)
  end

  it 'includes the cached count of members with expiring payment methods' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['membersWithExpiringPaymentMethods']).to eq(4)
  end

  it 'includes the count of lost members' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['lostMembers']).to eq(1)
  end

  it 'uses the shared aggregation for lost members by month' do
    rows = [{ month: '2024-01', count: 2 }, { month: '2024-02', count: 0 }]
    expect(Service::Analytics::Members).to receive(:lost_members_by_month).with(
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 12, 31)
    ).and_return(rows)

    get :member_losses, params: { year: 2024 }, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body, symbolize_names: true)).to eq(rows)
  end

  it 'uses the shared aggregation for active members' do
    rows = [{ date: '2024-01', count: 3 }, { date: '2024-02', count: 0 }]
    expect(Service::Analytics::Members).to receive(:active_members_by_month).with(
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 12, 31),
      statuses: Member::ACTIVE_MEMBERSHIP_STATUSES
    ).and_return(rows)

    get :active_members, params: { year: 2024 }, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body, symbolize_names: true)).to eq(rows)
  end

  it 'uses exclusive next-year cutoffs and keeps pending credits globally scoped' do
    VolunteerCredit.collection.insert_many([
      { member_id: admin.id, status: 'approved', credit_value: 2.0, created_at: Time.utc(2024, 12, 31, 23, 59, 59, 500_000) },
      { member_id: admin.id, status: 'approved', credit_value: 4.0, created_at: Time.utc(2025, 1, 1) },
      { member_id: admin.id, status: 'pending', credit_value: 1.0, created_at: Time.utc(2023, 1, 1) }
    ])
    VolunteerTask.collection.insert_many([
      { status: 'completed', completed_at: Time.utc(2024, 12, 31, 23, 59, 59, 500_000) },
      { status: 'completed', completed_at: Time.utc(2025, 1, 1) }
    ])

    get :volunteer_summary, params: { year: 2024 }, format: :json

    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(body['credits_by_month']).to eq([{ 'month' => '2024-12', 'count' => 1, 'total_value' => 2.0 }])
    expect(body['tasks_by_month']).to eq([{ 'month' => '2024-12', 'count' => 1 }])
    expect(body).to include('total_credits' => 1, 'total_credit_value' => 2.0, 'pending_credits' => 1)
  end
end
