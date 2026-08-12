require "rails_helper"

RSpec.describe SlackVolunteerJob, type: :job do
  let(:job) { described_class.new }
  let(:shop_a) { create(:shop, name: "Shop A") }
  let(:shop_b) { create(:shop, name: "Shop B") }
  let(:claimant) { create(:member, :current) }
  let(:resource_manager) do
    create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop_a.id.to_s])
  end

  before do
    allow(job).to receive(:post_response)
    allow_any_instance_of(VolunteerTask).to receive(:notify_member_task_released)
    allow_any_instance_of(VolunteerTask).to receive(:notify_task_verified)
    allow_any_instance_of(VolunteerTask).to receive(:enqueue_volunteer_canvas_sync)
    allow_any_instance_of(VolunteerCredit).to receive(:notify_member_credit_awarded)
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
  end

  def connect(member, slack_id)
    SlackUser.create!(member: member, slack_id: slack_id)
  end

  def perform_as(slack_id, text)
    job.perform(
      "response_url" => "https://example.test/response",
      "user_id" => slack_id,
      "text" => text
    )
  end

  def task_for(shop, status)
    VolunteerTask.create!(
      title: "Volunteer task",
      description: "Help the shop",
      shop_id: shop.id,
      created_by_id: resource_manager.id,
      claimed_by_id: claimant.id,
      claimed_at: 1.hour.ago,
      status: status
    )
  end

  shared_examples "shop-scoped task command" do |command, initial_status, allowed_status|
    it "prevents an RM from #{command}ing a task in another shop" do
      connect(resource_manager, "URM")
      task = task_for(shop_b, initial_status)

      perform_as("URM", "#{command} #{task.task_number} reason")

      expect(task.reload.status).to eq(initial_status)
      expect(VolunteerCredit.where(task_id: task.id)).to be_empty
      expect(job).to have_received(:post_response).with(
        "https://example.test/response",
        :ephemeral,
        a_string_including("not authorized")
      )
    end

    it "allows an RM to #{command} a task in a managed shop" do
      connect(resource_manager, "URM")
      task = task_for(shop_a, initial_status)

      perform_as("URM", "#{command} #{task.task_number} reason")

      expect(task.reload.status).to eq(allowed_status)
    end
  end

  include_examples "shop-scoped task command", "verify", "pending", "completed"
  include_examples "shop-scoped task command", "release", "claimed", "available"
  include_examples "shop-scoped task command", "reject", "pending", "available"

  %i[admin board_member].each do |role|
    it "allows a #{role} to administer tasks globally" do
      member = create(:member, role, :current)
      connect(member, "UGLOBAL")
      task = task_for(shop_b, "pending")

      perform_as("UGLOBAL", "verify #{task.task_number}")

      expect(task.reload.status).to eq("completed")
      expect(VolunteerCredit.where(task_id: task.id, issued_by_id: member.id)).to exist
    end
  end

  it "authorizes the selected child rather than a managed parent" do
    connect(resource_manager, "URM")
    parent = task_for(shop_a, "repeatable")
    child = task_for(shop_b, "pending")
    child.update!(parent_task_id: parent.id)

    perform_as("URM", "verify #{parent.task_number}")

    expect(child.reload.status).to eq("pending")
    expect(VolunteerCredit.where(task_id: child.id)).to be_empty
  end

  it "allows a parent-task command when the selected child is managed" do
    connect(resource_manager, "URM")
    parent = task_for(shop_b, "repeatable")
    child = task_for(shop_a, "claimed")
    child.update!(parent_task_id: parent.id)

    perform_as("URM", "release #{parent.task_number} stale")

    expect(child.reload.status).to eq("denied")
  end

  it "prevents an RM from closing an event in another shop" do
    connect(resource_manager, "URM")
    event = VolunteerEvent.create!(
      title: "Shop B event",
      description: "Help Shop B",
      shop_id: shop_b.id,
      created_by_id: resource_manager.id
    )

    perform_as("URM", "close E#{event.event_number}")

    expect(event.reload.status).to eq("open")
    expect(VolunteerCredit.where(event_id: event.id)).to be_empty
    expect(job).to have_received(:post_response).with(
      "https://example.test/response",
      :ephemeral,
      a_string_including("not authorized")
    )
  end
end
