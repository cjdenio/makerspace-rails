require 'swagger_helper'

RSpec.describe 'Repair ticket catalog references', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let!(:ticket) { FixTicket.create!(reporter_id: member.id, title: 'Broken tool', description: 'Needs repair', category: 'broken', submission_key: SecureRandom.uuid, shop_id: shop.id, tool_id: tool.id) }
  before do
    ActiveJob::Base.queue_adapter = :test
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
  end
  path '/admin/tools' do
    post 'Create a tool with a name unique within its shop' do
      tags 'Tools'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { allOf: [{ '$ref' => '#/components/schemas/ToolSettingsWrite' }], required: ['name', 'shop_id'] }
      let(:body) { { name: tool.name, shop_id: shop.id.to_s } }
      response '200', 'Created tool including its availability' do
        schema '$ref' => '#/components/schemas/Tool'
        let(:body) { { name: 'New unique tool', shop_id: shop.id.to_s } }
        run_test! { |response| expect(response.parsed_body['outOfService']).to eq(false) }
      end
      response '422', 'Another tool in the same shop already has this name' do
        run_test! { |response| expect(response.body).to include('already exists in this shop') }
      end
    end
  end
  %w[/admin/tools/{id} /admin/shops/{id}].each do |endpoint|
    path endpoint do
      parameter name: :id, in: :path, type: :string
      let(:id) { endpoint.include?('/tools/') ? tool.id.to_s : shop.id.to_s }
      delete 'Delete catalog resource unless referenced by a repair ticket' do
        tags 'Tools'
        security [sessionAuth: []]
        produces 'application/json'
        response '409', 'Repair ticket reference prevents deletion, including closed tickets and force deletion' do
          schema '$ref' => '#/components/schemas/FixError'
          before { ticket.set(status: 'resolved') }
          run_test! { expect(Tool.where(id: tool.id)).to exist }
        end
      end
    end
  end
  path '/admin/tools/{id}' do
    parameter name: :id, in: :path, type: :string
    let(:id) { tool.id.to_s }
    %i[put patch].each do |verb|
      public_send(verb, 'Update tool; ticket references prevent moving shops') do
        tags 'Tools'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ToolSettingsWrite' }
        let(:body) { { shop_id: create(:shop).id.to_s } }
        response '200', 'Updated tool including its availability' do
          schema '$ref' => '#/components/schemas/Tool'
          let(:body) { { name: 'Updated tool' } }
          before { tool.set(out_of_service: true) }
          run_test! { |response| expect(response.parsed_body).to include('name' => 'Updated tool', 'outOfService' => true) }
        end
        response '409', 'Repair ticket reference prevents shop move' do
          schema '$ref' => '#/components/schemas/FixError'
          run_test! { expect(tool.reload.shop_id).to eq(shop.id) }
        end
        response '422', 'Another tool in the same shop already has this name' do
          let(:other) { create(:tool, shop: shop, disabled: true) }
          let(:body) { { name: other.name } }
          run_test! do |response|
            expect(response.body).to include('already exists in this shop')
            expect(tool.reload.name).not_to eq(other.name)
          end
        end
      end
    end
  end
  it 'retains hidden tool approver ticket access without granting unrelated tools' do
    approver = create(:member, :current)
    CheckoutApprover.create!(member_id: approver.id, tool_ids: [tool.id.to_s])
    tool.update!(disabled: true)
    policy = FixTicketPolicy.new(approver, ticket)
    expect(policy.read?).to be(true)
    expect(policy.note?).to be(true)
    expect(policy.change_status?).to be(true)
    expect(policy.scope('queue').pluck(:id)).to include(ticket.id)
    other = ticket.dup
    other.tool_id = create(:tool, shop: shop).id
    expect(FixTicketPolicy.new(approver, other).read?).to be(false)
  end
end
