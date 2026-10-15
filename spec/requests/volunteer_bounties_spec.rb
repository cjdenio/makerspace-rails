require "rails_helper"
require "cgi"

RSpec.describe "Public volunteer bounty XML", type: :request do
  let(:admin) { create(:member, :admin) }
  let(:woodshop) { create(:shop, name: "Wood Working") }
  let(:metalshop) { create(:shop, name: "Metal Shop") }

  def create_task(title, shop = nil)
    VolunteerTask.create!(
      title: title,
      description: "Public bounty",
      credit_value: 1,
      created_by_id: admin.id,
      shop_id: shop&.id
    )
  end

  it "URL-decodes and case-insensitively substring-filters by assigned shop" do
    create_task("Wood task", woodshop)
    create_task("Metal task", metalshop)
    create_task("No shop task")

    get "/volunteer/bounties.xml?shop=#{CGI.escape('WOOD')}"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/xml")
    expect(response.body).to include("Wood task")
    expect(response.body).not_to include("Metal task", "No shop task")
  end

  it "returns every public bounty when no shop parameter is supplied" do
    create_task("Wood task", woodshop)
    create_task("No shop task")

    get "/volunteer/bounties.xml"

    expect(response.body).to include("Wood task", "No shop task")
  end
end
