require "rails_helper"

RSpec.describe "Reservation blackout API", type: :request do
  let(:shop) { create(:shop) }
  let(:other_shop) { create(:shop) }
  let(:manager) do
    create(
      :member,
      :resource_manager,
      :current,
      resource_manager_shop_ids: [shop.id.to_s]
    )
  end
  let(:params) do
    {
      title: "Open House",
      shop_id: shop.id.to_s,
      recurrence: "weekly",
      weekday: 1,
      start_time: "17:00",
      end_time: "20:00"
    }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    sign_in manager
  end

  it "allows a resource manager to manage blackouts for an assigned shop" do
    post "/api/admin/reservation_blackouts", params: params

    expect(response).to have_http_status(:created)
    blackout = ReservationBlackout.first
    expect(blackout.created_by_id).to eq(manager.id)
    expect(JSON.parse(response.body)).to include(
      "title" => "Open House",
      "shopId" => shop.id.to_s
    )
    expect(AuditLog.where(event_type: "reservation_blackout_created").exists?).to be(true)
    expect(ReservationSlackCanvasSyncJob).to have_been_enqueued
  end

  it "does not expose or allow mutation of another shop" do
    hidden = create(:reservation_blackout, shop: other_shop)

    get "/api/admin/reservation_blackouts"
    expect(JSON.parse(response.body).map { |row| row["id"] }).not_to include(hidden.id.to_s)

    put "/api/admin/reservation_blackouts/#{hidden.id}", params: { title: "Changed" }
    expect(response).to have_http_status(:forbidden)
  end

  it "does not let a resource manager move a blackout to an unmanaged shop" do
    blackout = create(:reservation_blackout, shop: shop)

    put "/api/admin/reservation_blackouts/#{blackout.id}",
      params: params.merge(shop_id: other_shop.id.to_s)

    expect(response).to have_http_status(:forbidden)
    expect(blackout.reload.shop_id).to eq(shop.id)
  end

  it "allows admins to move a blackout between shops" do
    blackout = create(:reservation_blackout, shop: shop)
    sign_out manager
    sign_in create(:member, :admin, :current)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    put "/api/admin/reservation_blackouts/#{blackout.id}",
      params: params.merge(shop_id: other_shop.id.to_s)

    expect(response).to have_http_status(:ok)
    expect(blackout.reload.shop_id).to eq(other_shop.id)
    expect(ReservationSlackCanvasSyncJob).to have_been_enqueued
      .with(shop.id.to_s, kind_of(Array))
    expect(ReservationSlackCanvasSyncJob).to have_been_enqueued
      .with(other_shop.id.to_s, kind_of(Array))
  end
end
