require "rails_helper"

RSpec.describe Service::SlackConnector do
  around do |example|
    previous_bot_token = ENV["SLACK_BOT_TOKEN"]
    previous_admin_token = ENV["SLACK_ADMIN_TOKEN"]
    example.run
  ensure
    ENV["SLACK_BOT_TOKEN"] = previous_bot_token
    ENV["SLACK_ADMIN_TOKEN"] = previous_admin_token
  end

  it "prefers the bot token for ordinary API calls when both tokens exist" do
    ENV["SLACK_BOT_TOKEN"] = "xoxb-bot"
    ENV["SLACK_ADMIN_TOKEN"] = "xoxp-admin"
    bot_client = instance_double(Slack::Web::Client)

    expect(Slack::Web::Client).to receive(:new)
      .with(token: "xoxb-bot")
      .and_return(bot_client)

    expect(described_class.client).to eq(bot_client)
  end

  it "uses the admin token for ordinary calls when it is the only token" do
    ENV.delete("SLACK_BOT_TOKEN")
    ENV["SLACK_ADMIN_TOKEN"] = "xoxp-admin"
    admin_client = instance_double(Slack::Web::Client)

    expect(Slack::Web::Client).to receive(:new)
      .with(token: "xoxp-admin")
      .and_return(admin_client)

    expect(described_class.client).to eq(admin_client)
  end

  it "uses the admin token for privileged calls when both tokens exist" do
    ENV["SLACK_BOT_TOKEN"] = "xoxb-bot"
    ENV["SLACK_ADMIN_TOKEN"] = "xoxp-admin"
    admin_client = instance_double(Slack::Web::Client)

    expect(Slack::Web::Client).to receive(:new)
      .with(token: "xoxp-admin")
      .and_return(admin_client)

    expect(described_class.admin_client("users.profile.set")).to eq(admin_client)
  end

  it "routes billable-user lookup through the admin token" do
    ENV["SLACK_BOT_TOKEN"] = "xoxb-bot"
    ENV["SLACK_ADMIN_TOKEN"] = "xoxp-admin"
    admin_client = instance_double(Slack::Web::Client)
    response = double("Billable response")

    expect(Slack::Web::Client).to receive(:new)
      .with(token: "xoxp-admin")
      .and_return(admin_client)
    expect(admin_client).to receive(:team_billableInfo)
      .with(user: "U123")
      .and_return(response)

    expect(described_class.team_billable_info(user: "U123")).to eq(response)
  end

  it "reports privileged calls to stderr and Honeybadger when only a bot token exists" do
    ENV["SLACK_BOT_TOKEN"] = "xoxb-bot"
    ENV.delete("SLACK_ADMIN_TOKEN")
    allow(Rails.logger).to receive(:error)
    expect(Honeybadger).to receive(:notify).with(
      "Slack admin token required",
      context: {
        operation: "users.admin.setInactive",
        slack_bot_token_present: true
      }
    ) if defined?(Honeybadger)

    result = nil
    expect {
      result = described_class.admin_client("users.admin.setInactive")
    }.to output(
      a_string_including(
        "[SlackAdminTokenRequired]",
        "operation=users.admin.setInactive",
        "SLACK_ADMIN_TOKEN is required"
      )
    ).to_stderr

    expect(result).to be_nil
  end
end
