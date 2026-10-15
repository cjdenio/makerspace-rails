require "rails_helper"

RSpec.describe Service::SlackProfileSync do
  it "uses the explicitly routed admin client to edit another user's profile" do
    member = create(:member, :current, status: "suspended")
    SlackUser.create!(
      member: member,
      slack_id: "U123",
      name: "member.name",
      real_name: "Member Name"
    )
    admin_client = instance_double(Slack::Web::Client)
    allow(Service::SlackConnector).to receive(:admin_client)
      .with("users.profile.set")
      .and_return(admin_client)
    expect(admin_client).to receive(:users_profile_set).with(
      user: "U123",
      profile: {
        Service::SlackProfileSync.send(:status_field) => {
          value: "suspended"
        }
      }
    )

    expect(described_class.sync_one(member)).to eq(member)
  end

  it "waits for Slack's Retry-After duration and retries a rate-limited profile update" do
    member = create(:member, :current)
    SlackUser.create!(member: member, slack_id: "U123", name: "member.name", real_name: "Member Name")
    admin_client = instance_double(Slack::Web::Client)
    response = double(headers: { "retry-after" => "10" })
    error = Slack::Web::Api::Errors::TooManyRequestsError.new(response)
    attempts = 0
    allow(Service::SlackConnector).to receive(:admin_client).and_return(admin_client)
    allow(admin_client).to receive(:users_profile_set) do
      attempts += 1
      raise error if attempts == 1
    end
    allow(Service::SlackConnector).to receive(:sleep)

    expect(described_class.sync_one(member)).to eq(member)
    expect(Service::SlackConnector).to have_received(:sleep).with(10)
    expect(admin_client).to have_received(:users_profile_set).twice
  end

  it "materializes and randomizes eligible members before syncing them" do
    first_member = instance_double(Member)
    second_member = instance_double(Member)
    members = [first_member, second_member]
    scope = double
    allow(SystemConfig).to receive(:enabled?)
      .with(SystemConfig::SLACK_PROFILE_SYNC_ENABLED)
      .and_return(true)
    allow(SystemConfig).to receive(:get).with(described_class::LAST_RUN_KEY).and_return(nil)
    allow(SystemConfig).to receive(:set)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_ADMIN_TOKEN").and_return("token")
    allow(Member).to receive(:where).and_return(scope)
    allow(scope).to receive(:where).and_return(scope)
    allow(scope).to receive(:to_a).and_return(members)
    allow(members).to receive(:shuffle).and_return([second_member, first_member])
    allow(described_class).to receive(:sync_one)

    described_class.sync_all

    expect(described_class).to have_received(:sync_one).with(second_member).ordered
    expect(described_class).to have_received(:sync_one).with(first_member).ordered
  end
end
