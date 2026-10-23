require "rails_helper"

RSpec.describe "Volunteer task shop authorization", type: :request do
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
    allow(Service::SlackConnector).to receive(:enque_message)
    sign_in resource_manager
  end

  def create_task(shop)
    VolunteerTask.create!(
      title: "Clean the shop",
      description: "Sweep and organize the work area",
      shop_id: shop.id,
      created_by_id: resource_manager.id
    )
  end

  it "requires an RM to assign a task to a managed shop" do
    post "/api/admin/volunteer_tasks", params: {
      title: "Global task",
      description: "No shop supplied"
    }

    expect(response).to have_http_status(:forbidden)
    expect(VolunteerTask.where(title: "Global task")).to be_empty
  end

  it "rejects task creation in an unmanaged shop" do
    post "/api/admin/volunteer_tasks", params: {
      title: "Other shop task",
      description: "Not managed",
      shop_id: unmanaged_shop.id.to_s
    }

    expect(response).to have_http_status(:forbidden)
    expect(VolunteerTask.where(title: "Other shop task")).to be_empty
  end

  it "allows task creation in a managed shop" do
    post "/api/admin/volunteer_tasks", params: {
      title: "Managed task",
      description: "Managed",
      shop_id: managed_shop.id.to_s
    }

    expect(response).to have_http_status(:ok)
    expect(VolunteerTask.find_by(title: "Managed task").shop_id).to eq(managed_shop.id)
  end

  it "rejects an update when the existing task belongs to an unmanaged shop" do
    task = create_task(unmanaged_shop)

    put "/api/admin/volunteer_tasks/#{task.id}", params: { title: "Changed" }

    expect(response).to have_http_status(:forbidden)
    expect(task.reload.title).to eq("Clean the shop")
  end

  {
    complete: [:post, {}],
    release: [:post, { reason: "No longer available" }],
    reject_pending: [:post, { reason: "Work was incomplete" }],
    cancel: [:post, {}],
    reset_cooldown: [:post, {}]
  }.each do |action, (verb, request_params)|
    it "rejects #{action} when the existing task belongs to an unmanaged shop" do
      task = create_task(unmanaged_shop)
      original_attributes = task.reload.attributes

      public_send(
        verb,
        "/api/admin/volunteer_tasks/#{task.id}/#{action}",
        params: request_params
      )

      expect(response).to have_http_status(:forbidden)
      expect(task.reload.attributes).to eq(original_attributes)
      expect(VolunteerCredit.where(task_id: task.id)).to be_empty
    end
  end

  it "does not let an RM detach a task from its managed shop" do
    task = create_task(managed_shop)

    put "/api/admin/volunteer_tasks/#{task.id}", params: { shop_id: "" }

    expect(response).to have_http_status(:forbidden)
    expect(task.reload.shop_id).to eq(managed_shop.id)
  end

  it "rejects moving a task from a managed shop to an unmanaged shop" do
    task = create_task(managed_shop)

    put "/api/admin/volunteer_tasks/#{task.id}",
      params: { shop_id: unmanaged_shop.id.to_s }

    expect(response).to have_http_status(:forbidden)
    expect(task.reload.shop_id).to eq(managed_shop.id)
  end

  it "allows an RM to update a task in their managed shop without resending shop_id" do
    task = create_task(managed_shop)

    put "/api/admin/volunteer_tasks/#{task.id}", params: { title: "Updated" }

    expect(response).to have_http_status(:ok)
    expect(task.reload.title).to eq("Updated")
  end
end
