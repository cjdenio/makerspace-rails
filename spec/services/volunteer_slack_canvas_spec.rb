require "rails_helper"

RSpec.describe Service::VolunteerSlackCanvas do
  let(:shop) { create(:shop, name: "Woodshop", slack_channel: "woodshop") }
  let(:admin) { create(:member, :admin) }
  let(:tool) { create(:tool, shop: shop, name: "Table Saw") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:find_channel_id)
      .with("woodshop")
      .and_return("CWOOD")
    allow(Service::SlackConnector).to receive(:create_canvas)
      .with("Volunteer in Woodshop", channel_id: "CWOOD")
      .and_return("FVOLUNTEER")
    allow(Service::SlackConnector).to receive(:set_canvas_user_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
  end

  it "creates a channel-bound canvas, caches it, grants owners, and writes both lists" do
    rm_b = create(
      :member,
      :resource_manager,
      firstname: "Zoe",
      lastname: "Brown",
      resource_manager_shop_ids: [shop.id.to_s]
    )
    rm_a = create(
      :member,
      :resource_manager,
      firstname: "Amy",
      lastname: "Anderson",
      resource_manager_shop_ids: [shop.id.to_s]
    )
    SlackUser.create!(member: admin, slack_id: "UADMIN")
    SlackUser.create!(member: rm_b, slack_id: "UBROWN")
    SlackUser.create!(member: rm_a, slack_id: "UANDERSON")

    VolunteerTask.create!(
      title: "Organize lumber",
      description: "Sort the rack",
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop.id,
      prerequisite_tool_ids: [tool.id.to_s]
    )
    VolunteerEvent.create!(
      title: "Cleanup night",
      event_date: Date.current + 1.day,
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop.id
    )

    described_class.sync!(
      shop,
      create_if_needed: true,
      sync_owner_access: true
    )

    expect(shop.reload.volunteer_canvas_id).to eq("FVOLUNTEER")
    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with(
        "FVOLUNTEER",
        a_collection_containing_exactly("UADMIN", "UBROWN", "UANDERSON"),
        access_level: "owner"
      )
    expect(Service::SlackConnector).to have_received(:replace_canvas) do |_id, markdown|
      expect(markdown).to include(
        "Upcoming Volunteer Events",
        "Cleanup night",
        "Available Volunteer Tasks",
        "Organize lumber",
        "Requires: Table Saw",
        "Ask your Resource Managers"
      )
      expect(markdown.index("Amy Anderson")).to be < markdown.index("Zoe Brown")
      expect(markdown).to include("<@UANDERSON>", "<@UBROWN>")
    end
  end

  it "does not create an empty volunteer canvas" do
    described_class.sync!(shop, create_if_needed: true)

    expect(Service::SlackConnector).not_to have_received(:find_channel_id)
    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "strikes a newly claimed task when rewriting an existing canvas" do
    shop.update!(volunteer_canvas_id: "FEXISTING")
    task = VolunteerTask.create!(
      title: "Sweep floor",
      description: "Sweep",
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop.id,
      status: "claimed",
      claimed_by_id: create(:member, :current).id
    )

    described_class.sync!(shop, struck_task_id: task.id.to_s)

    expect(Service::SlackConnector).to have_received(:replace_canvas)
      .with("FEXISTING", a_string_matching(/~.*Sweep floor.*~/))
  end
end
