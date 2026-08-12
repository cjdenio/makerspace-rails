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
end
