require 'rails_helper'

RSpec.describe 'Checkout Required sheets', type: :request do
  let!(:shop) { create(:shop, slack_channel: 'shop-woodworking') }
  let!(:tool) { create(:tool, shop: shop, users_channel: 'tool-users', announce_channel: 'tool-announcements') }
  let!(:other_shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:tool_path) { "/api/tools/#{tool.id}/checkout_required_sheet" }
  let(:shop_path) { "/api/shops/#{shop.id}/checkout_required_sheet" }

  before do
    Shortcode.create_indexes
    allow(ShortUrl).to receive(:base_url).and_return('https://members.example.org')
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set).and_return(true)
  end

  def generate(path = tool_path, **params)
    post path, params: params, as: :json
  end

  %w[admin board_member resource_manager].each do |role|
    it "lets #{role} print authorized shops and tools" do
      member.update!(role: role, resource_manager_shop_ids: [shop.id.to_s])
      sign_in member
      [shop_path, tool_path].each do |path|
        generate(path)
        expect(response.status).to eq(200)
        expect(response.media_type).to eq('image/svg+xml')
        expect(response.headers['Content-Disposition']).to include('attachment', '.svg')
        expect(response.headers['Cache-Control']).to eq('private, no-store')
        expect(response.body).to include('SLACK: #shop-woodworking')
        expect(response.body).not_to include('tool-users', 'tool-announcements')
      end
    end
  end

  it 'rejects ordinary members and out-of-shop RMs before shortcode allocation' do
    sign_in member
    expect(ShortUrl).not_to receive(:allocate)
    generate
    expect(response.status).to eq(403)
    member.update!(role: 'resource_manager', resource_manager_shop_ids: [other_shop.id.to_s])
    generate(shop_path)
    expect(response.status).to eq(403)
    generate
    expect(response.status).to eq(403)
  end

  %i[tool_ids shop_ids].each do |assignment|
    it "honors #{assignment} approver grants only for tool sheets and rechecks revocation" do
      approver = CheckoutApprover.create!(member: member, assignment => [assignment == :tool_ids ? tool.id.to_s : shop.id.to_s])
      sign_in member
      generate
      expect(response.status).to eq(200)
      generate(shop_path)
      expect(response.status).to eq(403)
      other_tool = create(:tool, shop: other_shop)
      generate("/api/tools/#{other_tool.id}/checkout_required_sheet")
      expect(response.status).to eq(403)
      approver.destroy!
      generate
      expect(response.status).to eq(403)
    end
  end

  it 'honors materialized group tool grants' do
    group = ToolGroup.create!(shop: shop, name: 'Woodworking basics', included_tool_ids: [tool.id.to_s])
    CheckoutApprover.create!(member: member, tool_group_ids: [group.id.to_s])
    sign_in member
    generate
    expect(response.status).to eq(200)
  end

  it 'rejects expired and unsigned ordinary approvers' do
    CheckoutApprover.create!(member: member, tool_ids: [tool.id.to_s])
    sign_in member
    member.update!(expirationTime: 1)
    generate
    expect(response.status).to eq(403)
    member.update!(expirationTime: 1.year.from_now.to_i * 1000, member_contract_signed_date: nil)
    generate
    expect(response.status).to eq(403)
  end

  it 'requires authentication' do
    expect(ShortUrl).not_to receive(:allocate)
    generate
    expect(response.status).to eq(401)
  end

  it 'does not bypass a pending TOTP challenge' do
    member.update!(role: 'admin', password: 'password123', otp_required_for_login: true,
      otp_secret_encrypted: TotpService.encrypt(TotpService.generate_secret))
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123' } }, as: :json
    expect(response.status).to eq(202)
    expect(ShortUrl).not_to receive(:allocate)
    generate
    expect(response.status).to eq(401)
  end

  it 'blocks hidden and missing resources and open tools, but allows outages' do
    member.update!(role: 'admin')
    sign_in member
    generate('/api/tools/not-an-id/checkout_required_sheet')
    expect(response.status).to eq(404)
    generate("/api/tools/#{BSON::ObjectId.new}/checkout_required_sheet")
    expect(response.status).to eq(404)
    tool.set(disabled: true)
    generate
    expect(response.status).to eq(404)
    tool.set(disabled: false, open: true)
    generate
    expect(response.status).to eq(422)
    tool.set(open: false, out_of_service: true)
    generate
    expect(response.status).to eq(200)
    shop.set(disabled: true)
    [shop_path, tool_path].each do |path|
      generate(path)
      expect(response.status).to eq(404)
    end
  end

  it 'returns the same missing-resource response for hidden resources outside the viewer authority' do
    sign_in member
    expect(ShortUrl).not_to receive(:allocate)
    expect(CheckoutRequiredSheetPolicy).not_to receive(:new)
    generate("/api/tools/#{BSON::ObjectId.new}/checkout_required_sheet")
    missing_body = response.body
    expect(response.status).to eq(404)

    tool.set(disabled: true)
    generate
    expect(response.status).to eq(404)
    expect(response.body).to eq(missing_body)

    tool.set(disabled: false)
    shop.set(disabled: true)
    [shop_path, tool_path, '/api/shops/not-an-id/checkout_required_sheet',
      "/api/shops/#{BSON::ObjectId.new}/checkout_required_sheet"].each do |path|
      generate(path)
      expect(response.status).to eq(404)
      expect(response.body).to eq(missing_body)
      expect(response.media_type).to eq('application/json')
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(response.headers['Content-Disposition']).to be_nil
    end
  end

  it 'warns when the shop channel is missing, supports one sign, and reuses the permanent code' do
    member.update!(role: 'admin')
    shop.set(slack_channel: nil)
    sign_in member
    generate
    expect(response.headers['X-Checkout-Sheet-Warning']).to eq('missing_shop_channel')
    expect(response.body).not_to include('SLACK:')
    expect(Shortcode.count).to eq(1)
    generate(tool_path, copies: 1)
    expect(response.status).to eq(200)
    expect(Nokogiri::XML(response.body).xpath('//*[@class="checkout-sign"]').length).to eq(1)
    expect(Shortcode.count).to eq(1)
    expect(Shortcode.first.target_url).to eq("/api/tool/#{tool.id}/public.html")
  end

  it 'rejects invalid copies and fails closed when shortcode storage is unavailable' do
    member.update!(role: 'admin')
    sign_in member
    generate(tool_path, copies: 3)
    expect(response.status).to eq(422)
    expect(Shortcode.count).to eq(0)
    allow(ShortUrl).to receive(:allocate).and_raise(ShortUrl::Unavailable)
    generate
    expect(response.status).to eq(503)
    expect(response.media_type).to eq('application/json')
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  it 'reports capabilities consistently in all screen catalogs' do
    member.update!(role: 'resource_manager', resource_manager_shop_ids: [shop.id.to_s])
    sign_in member
    %w[/api/shops /api/admin/shops].each do |path|
      get path, as: :json
      expect(response.parsed_body.find { |row| row['id'] == shop.id.to_s }['canGenerateCheckoutRequiredSheet']).to be(true)
    end
    get '/api/admin/tools', as: :json
    expect(response.parsed_body.first['canGenerateCheckoutRequiredSheet']).to be(true)
    get '/api/workshops', as: :json
    row = response.parsed_body['workshops'].find { |candidate| candidate['id'] == shop.id.to_s }
    expect(row['canGenerateCheckoutRequiredSheet']).to be(true)
    expect(row['tools'].first['canGenerateCheckoutRequiredSheet']).to be(true)
    expect(response.parsed_body['workshops'].find { |candidate| candidate['id'] == other_shop.id.to_s }['canGenerateCheckoutRequiredSheet']).to be(false)
  end

  it 'adds the capability without changing the existing shop catalog reservation fields' do
    member.update!(status: 'pending')
    sign_in member
    get '/api/shops', as: :json
    row = response.parsed_body.find { |candidate| candidate['id'] == shop.id.to_s }
    expect(row['reservable']).to eq(shop.reservable)
    expect(row['canGenerateCheckoutRequiredSheet']).to be(false)
  end

  it 'requires CSRF even for an authorized member' do
    member.update!(role: 'admin')
    sign_in member
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    expect(ShortUrl).not_to receive(:allocate)
    generate
    expect(response.status).to eq(401)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
