require "rails_helper"

RSpec.describe "Checkout links", type: :request do
  let(:member) { create(:member, status: "pending", expirationTime: nil) }
  let(:shop) { create(:shop) }
  let!(:tool) { create(:tool, shop: shop, allow_pending: true) }
  before { allow(REDIS).to receive(:set).and_return(true) }

  it "preserves the anonymous destination without creating a request" do
    get "/tools/#{tool.id}/request-checkout"
    expect(response).to redirect_to("/login?return_to=%2Ftools%2F#{tool.id}%2Frequest-checkout")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    expect(ToolCheckoutRequest.count).to eq(0)
  end

  it "sends an anonymous visitor to sign in and back to the check-out-member link, without creating anything" do
    get "/tools/#{tool.id}/check-out-member"

    expect(response).to redirect_to("/login?return_to=%2Ftools%2F#{tool.id}%2Fcheck-out-member")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    expect(ToolCheckout.count).to eq(0)
  end

  it "serves the app shell for a signed-in member and hides unavailable tools" do
    sign_in member
    get "/tools/#{tool.id}/check-out-member"
    expect(response).to have_http_status(:ok)

    tool.update!(disabled: true)
    get "/tools/#{tool.id}/check-out-member"
    expect(response).to have_http_status(:not_found)
  end

  it "allows administrative editing of checkout exemption" do
    admin = create(:member, role: "admin")
    sign_in admin
    put "/api/admin/tools/#{tool.id}", params: { open: true }
    expect(response).to have_http_status(:ok)
    expect(tool.reload.open).to eq(true)
    expect(response.parsed_body["open"]).to eq(true)
  end

  it "provides selected context and explanatory states" do
    sign_in member
    get "/tools/#{tool.id}/request-checkout"
    expect(response).to have_http_status(:ok)
    expect(ToolCheckoutRequest.count).to eq(0)
    get "/api/tools/#{tool.id}/coreq.html"
    expect(response.parsed_body["eligible"]).to eq(true)
    expect(response.parsed_body.fetch("tool")["id"]).to eq(tool.id.to_s)
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    tool.update!(open: true)
    get "/api/tools/#{tool.id}/coreq.html"
    expect(response.parsed_body["reason"]).to eq("No checkout required")
    post "/api/tool_checkout_requests", params: { tool_id: tool.id.to_s }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ToolCheckoutRequest.count).to eq(0)
  end

  it "rechecks visibility on submission and shell access" do
    sign_in member
    get "/api/tools/#{tool.id}/coreq.html"
    shop.update!(disabled: true)
    ["/tools/#{tool.id}/request-checkout", "/api/tools/#{tool.id}/coreq.html"].each do |path|
      get path
      expect(response.status).to eq(404)
      expect(response.body).to eq("Not Found")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    post "/api/tool_checkout_requests", params: { tool_id: tool.id.to_s }
    expect(response.status).to eq(404)
    expect(response.body).to eq("Not Found")
  end

  it "reports existing requests and allows cancellation after opening a tool" do
    sign_in member
    post "/api/tool_checkout_requests", params: { tool_id: tool.id.to_s }
    checkout_request = ToolCheckoutRequest.last
    get "/api/tools/#{tool.id}/coreq.html"
    expect(response.parsed_body["reason"]).to include("open request")
    tool.update!(open: true)
    delete "/api/tool_checkout_requests/#{checkout_request.id}"
    expect(response).to have_http_status(:no_content)
    expect(checkout_request.reload.status).to eq("deleted")
  end
end
