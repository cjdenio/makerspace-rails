require "rails_helper"

RSpec.describe "Volunteer prerequisite eligibility", type: :request do
  let(:admin) { create(:member, :admin) }
  let(:member) { create(:member, status: "activeMember", role: "member") }
  let(:shop) { create(:shop, name: "Woodshop") }
  let(:required_tool) { create(:tool, shop: shop, name: "Table Saw") }
  let(:other_tool) { create(:tool, shop: shop, name: "Planer") }

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(SlackUser).to receive(:find_by).and_return(nil)
  end

  def task(title:, prerequisite_tool_ids: [])
    VolunteerTask.create!(
      title: title,
      description: "Help in the shop",
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop.id,
      prerequisite_tool_ids: prerequisite_tool_ids
    )
  end

  def event(title:, prerequisite_tool_ids: [])
    VolunteerEvent.create!(
      title: title,
      description: "Help at the event",
      credit_value: 1,
      event_date: Date.current,
      created_by_id: admin.id,
      shop_id: shop.id,
      prerequisite_tool_ids: prerequisite_tool_ids
    )
  end

  it "shows regular members only tasks whose prerequisites they meet" do
    open_task = task(title: "Open task")
    eligible_task = task(
      title: "Eligible task",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    hidden_task = task(
      title: "Hidden task",
      prerequisite_tool_ids: [other_tool.id.to_s]
    )
    create(:tool_checkout, member: member, tool: required_tool)
    sign_in member

    get "/api/volunteer/tasks"

    ids = JSON.parse(response.body).map { |record| record.fetch("id") }
    expect(ids).to contain_exactly(open_task.id.to_s, eligible_task.id.to_s)
    expect(ids).not_to include(hidden_task.id.to_s)
  end

  it "rejects a direct claim and explains the missing checkout" do
    restricted_task = task(
      title: "Restricted task",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    sign_in member

    post "/api/volunteer/tasks/#{restricted_task.id}/claim"

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).fetch("error")).to include("Table Saw")
    expect(restricted_task.reload.status).to eq("available")
  end

  it "does not list or permit claims by pending members with prerequisites" do
    pending_member = create(:member, status: "pending")
    restricted_task = task(
      title: "Pending-ineligible task",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    create(:tool_checkout, member: pending_member, tool: required_tool)
    sign_in pending_member

    get "/api/volunteer/tasks"
    expect(JSON.parse(response.body).map { |record| record.fetch("id") })
      .not_to include(restricted_task.id.to_s)

    post "/api/volunteer/tasks/#{restricted_task.id}/claim"
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).fetch("error"))
      .to eq("Only active members may claim tasks")
    expect(restricted_task.reload.status).to eq("available")
  end

  it "filters events and rejects a direct check-in for a regular member" do
    open_event = event(title: "Open event")
    restricted_event = event(
      title: "Restricted event",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    sign_in member

    get "/api/volunteer/events"
    ids = JSON.parse(response.body).map { |record| record.fetch("id") }
    expect(ids).to contain_exactly(open_event.id.to_s)

    post "/api/volunteer/events/#{restricted_event.id}/checkin"
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).fetch("error")).to include("Table Saw")
  end

  it "shows all tasks and events to admins without prerequisite checkouts" do
    restricted_task = task(
      title: "Admin-visible task",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    restricted_event = event(
      title: "Admin-visible event",
      prerequisite_tool_ids: [required_tool.id.to_s]
    )
    sign_in admin

    get "/api/volunteer/tasks"
    expect(JSON.parse(response.body).map { |record| record.fetch("id") })
      .to include(restricted_task.id.to_s)

    get "/api/volunteer/events"
    expect(JSON.parse(response.body).map { |record| record.fetch("id") })
      .to include(restricted_event.id.to_s)
  end

  it "validates that prerequisite tools belong to the associated shop" do
    another_tool = create(:tool, shop: create(:shop))
    invalid_task = VolunteerTask.new(
      title: "Invalid",
      description: "Invalid prerequisite",
      credit_value: 1,
      shop_id: shop.id,
      prerequisite_tool_ids: [another_tool.id.to_s]
    )

    expect(invalid_task).not_to be_valid
    expect(invalid_task.errors[:prerequisite_tool_ids])
      .to include("must belong to the associated shop")
  end
end
