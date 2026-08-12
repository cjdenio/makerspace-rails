require "rails_helper"

RSpec.describe "Slack interactions", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(nil)
  end

  it "rejects unsigned requests when the signing secret is absent" do
    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to include(
      "error" => "Slack signing secret is not configured"
    )
  end

  it "allows the missing-secret bypass in development" do
    allow(Rails.env).to receive(:development?).and_return(true)

    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:ok)
  end
end
