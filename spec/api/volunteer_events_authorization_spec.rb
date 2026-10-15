require "rails_helper"

RSpec.describe "Volunteer event shop authorization", type: :request do
  let(:managed_shop) { create(:shop, name: "Managed Shop") }
  let(:unmanaged_shop) { create(:shop, name: "Unmanaged Shop") }
  let(:resource_manager) do
    create(
      :member,
      :resource_manager,
      :current,
      resource_manager_shop_ids: [managed_shop.id.to_s]
    )
  end

  before do
    sign_in resource_manager
  end

  def create_event(shop)
    VolunteerEvent.create!(
      title: "Volunteer orientation",
      shop_id: shop.id,
      created_by_id: resource_manager.id
    )
  end

  it "rejects an update when the existing event belongs to an unmanaged shop" do
    event = create_event(unmanaged_shop)

    put "/api/admin/volunteer_events/#{event.id}", params: { title: "Changed" }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.title).to eq("Volunteer orientation")
  end

  it "rejects closing an unmanaged event without issuing attendee credits" do
    attendee = create(:member, :current)
    event = create_event(unmanaged_shop)
    event.set(attendee_ids: [attendee.id])

    post "/api/admin/volunteer_events/#{event.id}/close"

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.status).to eq("open")
    expect(VolunteerCredit.where(member_id: attendee.id)).to be_empty
  end

  it "rejects adding an attendee to an unmanaged event" do
    attendee = create(:member, :current)
    event = create_event(unmanaged_shop)

    post "/api/admin/volunteer_events/#{event.id}/add_attendee",
      params: { member_id: attendee.id.to_s }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.attendee_ids).to be_empty
  end

  it "rejects removing an attendee from an unmanaged event" do
    attendee = create(:member, :current)
    event = create_event(unmanaged_shop)
    event.set(attendee_ids: [attendee.id])

    delete "/api/admin/volunteer_events/#{event.id}/remove_attendee",
      params: { member_id: attendee.id.to_s }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.attendee_ids).to eq([attendee.id])
    expect(event.attendee_removals).to be_empty
  end

  it "does not let an RM detach an event from its managed shop" do
    event = create_event(managed_shop)

    put "/api/admin/volunteer_events/#{event.id}", params: { shop_id: "" }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.shop_id).to eq(managed_shop.id)
  end

  it "rejects moving an event from a managed shop to an unmanaged shop" do
    event = create_event(managed_shop)

    put "/api/admin/volunteer_events/#{event.id}",
      params: { shop_id: unmanaged_shop.id.to_s }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.shop_id).to eq(managed_shop.id)
  end

  it "allows an RM to update an event in their managed shop without resending shop_id" do
    event = create_event(managed_shop)

    put "/api/admin/volunteer_events/#{event.id}", params: { title: "Updated" }

    expect(response).to have_http_status(:ok)
    expect(event.reload.title).to eq("Updated")
  end
end
