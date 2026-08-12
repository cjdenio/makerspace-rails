require "rails_helper"

RSpec.describe SlackVolunteerJob, type: :job do
  let(:job) { described_class.new }
  let(:member) { create(:member, status: "activeMember", role: "member") }
  let(:admin) { create(:member, :admin) }
  let(:shop) { create(:shop, name: "Woodshop") }
  let(:tool) { create(:tool, shop: shop, name: "Table Saw") }

  before do
    SlackUser.create!(member: member, slack_id: "UMEMBER")
    SlackUser.create!(member: admin, slack_id: "UADMIN")
    allow(job).to receive(:post_response)
  end

  def create_task(title, prerequisite_tool_ids: [])
    VolunteerTask.create!(
      title: title,
      description: "Help",
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop.id,
      prerequisite_tool_ids: prerequisite_tool_ids
    )
  end

  def perform_as(slack_id, text)
    job.perform(
      "response_url" => "https://example.test/response",
      "user_id" => slack_id,
      "text" => text
    )
  end

  it "hides tasks with unmet prerequisites from regular members" do
    create_task("Open task")
    create_task("Restricted task", prerequisite_tool_ids: [tool.id.to_s])

    perform_as("UMEMBER", "tasks")

    expect(job).to have_received(:post_response) do |_url, _type, message|
      expect(message).to include("Open task", "Shop: Woodshop")
      expect(message).not_to include("Restricted task")
    end
  end

  it "shows restricted tasks to admins" do
    create_task("Restricted task", prerequisite_tool_ids: [tool.id.to_s])

    perform_as("UADMIN", "tasks")

    expect(job).to have_received(:post_response)
      .with(
        "https://example.test/response",
        :ephemeral,
        a_string_including("Restricted task")
      )
  end

  it "rejects a direct Slack claim with the missing checkout name" do
    restricted = create_task(
      "Restricted task",
      prerequisite_tool_ids: [tool.id.to_s]
    )

    perform_as("UMEMBER", "claim #{restricted.task_number}")

    expect(job).to have_received(:post_response)
      .with(
        "https://example.test/response",
        :ephemeral,
        a_string_including("active checkouts for: Table Saw")
      )
    expect(restricted.reload.status).to eq("available")
  end

  it "rejects a Slack claim from a pending member with all prerequisites" do
    member.update!(status: "pending")
    create(:tool_checkout, member: member, tool: tool)
    restricted = create_task(
      "Pending-ineligible task",
      prerequisite_tool_ids: [tool.id.to_s]
    )

    perform_as("UMEMBER", "claim #{restricted.task_number}")

    expect(job).to have_received(:post_response)
      .with(
        "https://example.test/response",
        :ephemeral,
        a_string_including("Only active members can claim tasks")
      )
    expect(restricted.reload.status).to eq("available")
  end
end
