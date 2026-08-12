require "rails_helper"

RSpec.describe Service::SlackConnector do
  let(:client) { instance_double(Slack::Web::Client) }

  before do
    allow(described_class).to receive(:client).and_return(client)
    allow(described_class).to receive(:safe_channel)
      .with("U123")
      .and_return("U123")
  end

  it "schedules a Slack message and returns its scheduled message ID" do
    response = double(scheduled_message_id: "Q123")
    expect(client).to receive(:chat_scheduleMessage).with(
      channel: "U123",
      text: "Reservation reminder",
      post_at: 1_785_000_000
    ).and_return(response)

    result = described_class.schedule_slack_message(
      channel: "U123",
      text: "Reservation reminder",
      post_at: Time.at(1_785_000_000)
    )

    expect(result).to eq("Q123")
  end

  it "deletes a scheduled Slack message" do
    expect(client).to receive(:chat_deleteScheduledMessage).with(
      channel: "U123",
      scheduled_message_id: "Q123"
    )

    described_class.delete_scheduled_slack_message(
      channel: "U123",
      scheduled_message_id: "Q123"
    )
  end
end
