require 'swagger_helper'

RSpec.describe 'Bounty resource visibility', type: :request do
  let(:member) { create(:member, :current) }
  let(:creator) { create(:member, :admin, :current) }
  let(:hidden_shop) { create(:shop, name: 'Secret workshop', disabled: true) }
  let(:visible_shop) { create(:shop, name: 'Public workshop') }
  let(:hidden_tool) { create(:tool, shop: visible_shop, name: 'Secret machine', disabled: true) }
  let(:hidden_shop_tool) { create(:tool, shop: visible_shop, name: 'Private machine') }
  let(:visible_tool) { create(:tool, shop: visible_shop, name: 'Public machine', out_of_service: true) }
  let(:ticket) { create(:fix_ticket, reporter_id: creator.id, shop_id: hidden_shop.id) }
  let!(:task) do
    task = VolunteerTask.create!(title: 'Repair work', description: 'Replace switch', ticket_id: ticket.id,
      created_by_id: creator.id, shop_id: visible_shop.id,
      prerequisite_tool_ids: [hidden_tool.id.to_s, hidden_shop_tool.id.to_s, visible_tool.id.to_s])
    # Existing references can outlive catalog moves; project their current visibility.
    hidden_shop_tool.set(shop_id: hidden_shop.id)
    task.set(shop_id: hidden_shop.id)
    task
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
  end

  path '/volunteer/bounties.{format}' do
    parameter name: :format, in: :path, required: true, schema: { type: :string, enum: %w[json xml] }
    get 'Public bounty feed with hidden catalog references redacted', operation: { servers: [{ url: '/' }] } do
      tags 'Volunteer'
      security []
      produces 'application/json', 'application/xml'
      description 'Hidden shop names and prerequisite tools (including tools inside hidden shops) are omitted. Shop filtering only matches visible shop names. An optional deployment-configured feed token may be required.'
      parameter name: :shop, in: :query, required: false, schema: { type: :string }
      parameter name: :token, in: :query, required: false, schema: { type: :string }
      response '200', 'Public claimable bounty projections' do
        schema type: :array, items: { type: :object, required: %w[id title shop_name prerequisite_tools], properties: {
          id: { type: :string }, title: { type: :string }, shop_name: { type: :string, nullable: true },
          prerequisite_tools: { type: :array, items: { type: :string } }
        } }
        %w[json xml].each do |format|
          it "redacts #{format} resources and hidden-shop filter inference" do |example|
            get "/volunteer/bounties.#{format}"
            expect(response).to have_http_status(:ok)
            assert_response_matches_metadata(example.metadata) if format == 'json'
            expect(response.body).to include(task.title, visible_tool.name)
            expect(response.body).not_to include(hidden_shop.name, hidden_tool.name, hidden_shop_tool.name)
            get "/volunteer/bounties.#{format}", params: { shop: hidden_shop.name }
            expect(response.body).not_to include(task.title)
          end
        end
      end
    end
  end

  path '/volunteer/tasks/{id}/detail' do
    parameter name: :id, in: :path, type: :string
    get 'Read bounty detail with viewer-authorized resource references' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      let(:id) { task.id.to_s }
      before { sign_in member }
      response '200', 'Hidden references and legacy reporter-creator identity are redacted' do
        schema '$ref' => '#/components/schemas/FixBountyDetail'
        run_test! do |response|
          data = response.parsed_body
          expect(data).to include('shopId' => nil, 'shopName' => nil, 'createdById' => nil, 'createdByName' => nil,
            'prerequisiteToolIds' => [visible_tool.id.to_s], 'prerequisiteToolNames' => [visible_tool.name])
          expect(data.dig('capabilities', 'canClaim')).to be(false)
          expect(task.reload.prerequisite_tool_ids).to include(hidden_tool.id.to_s, hidden_shop_tool.id.to_s)
        end
      end
    end
  end

  it 'preserves authorized manager resources and independent creator identity' do
    admin = create(:member, :admin, :current)
    task.set(created_by_id: admin.id)
    sign_in admin
    get "/api/volunteer/tasks/#{task.id}/detail"
    expect(response.parsed_body).to include('shopId' => hidden_shop.id.to_s, 'shopName' => hidden_shop.name,
      'createdById' => admin.id.to_s, 'createdByName' => admin.fullname)
    expect(response.parsed_body['prerequisiteToolNames']).to contain_exactly(hidden_tool.name, hidden_shop_tool.name, visible_tool.name)
  end

  it 'redacts member lists, active claims, and failed-claim messages without relaxing prerequisites' do
    sign_in member
    post "/api/volunteer/tasks/#{task.id}/claim"
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include(hidden_tool.name, hidden_shop_tool.name, hidden_tool.id.to_s)
    [hidden_tool, hidden_shop_tool, visible_tool].each { |tool| create(:tool_checkout, member: member, tool: tool) }
    get '/api/volunteer/tasks'
    expect(response.parsed_body).to include(hash_including('id' => task.id.to_s, 'shopName' => nil, 'createdByName' => nil, 'prerequisiteToolNames' => [visible_tool.name]))
    task.set(status: 'claimed', claimed_by_id: member.id)
    get '/api/volunteer/tasks/my_claims'
    expect(response.body).not_to include(hidden_shop.name, hidden_tool.name, hidden_shop_tool.name, creator.fullname)
  end

  it 'redacts workshop and Slack projections even for checked-out hidden prerequisites' do
    task.set(shop_id: visible_shop.id)
    [hidden_tool, hidden_shop_tool, visible_tool].each { |tool| create(:tool_checkout, member: member, tool: tool) }
    projection = WorkshopSerializer.new(visible_shop, scope: member).volunteer_tasks.find { |row| row[:id] == task.id.to_s }
    expect(projection[:prerequisiteToolNames]).to eq([visible_tool.name])
    task.set(shop_id: hidden_shop.id)
    job = SlackVolunteerJob.new
    expect(job).to receive(:post_response) do |_, kind, text|
      expect(kind).to eq(:ephemeral)
      expect(text).to include(task.title)
      expect(text).not_to include(hidden_shop.name)
    end
    job.send(:handle_tasks, 'https://example.test/response', member)
    label = Service::VolunteerSlackCanvas.send(:prerequisite_label, task)
    expect(label).to include(visible_tool.name)
    expect(label).not_to include(hidden_tool.name, hidden_shop_tool.name)
  end
end
