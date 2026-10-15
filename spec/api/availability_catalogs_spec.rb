require 'swagger_helper'

RSpec.describe 'Availability and volunteer credit catalogs', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop, reservable: true) }
  before do
    sign_in member
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
  end

  path '/reservation_catalog' do
    get 'List enabled reservation shops and their reservable tools' do
      parameter name: :include_groups, in: :query, required: false, schema: { type: :boolean }, description: 'Add toolGroups with expanded child details. Default omits groups for native compatibility.'
      tags 'Reservations'
      security [sessionAuth: []]
      produces 'application/json'
      description 'Out-of-service shops and all tools belonging to them are omitted. Shop entries include resourceManagers; tool entries include outOfService. Individually out-of-service tools remain visible for availability display.'
      response '200', 'Reservation catalog with availability and Resource Managers' do
        schema type: :object, required: %w[shops tools], properties: {
          shops: { type: :array, items: { '$ref' => '#/components/schemas/Shop' } },
          tools: { type: :array, items: { '$ref' => '#/components/schemas/Tool' } },
          toolGroups: { type: :array, description: 'Present only when include_groups=true.', items: { '$ref' => '#/components/schemas/ToolGroup' } }
        }
        let!(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
        let!(:available_tool) { create(:tool, shop: shop, reservable: true) }
        let!(:unavailable_tool) { create(:tool, shop: shop, reservable: true, out_of_service: true) }
        let!(:unavailable_shop) { create(:shop, reservable: true, out_of_service: true, out_of_service_note: 'Leak') }
        let!(:blocked_tool) { create(:tool, shop: unavailable_shop, reservable: true) }
        run_test! do |response|
          data = response.parsed_body
          expect(data['shops'].map { |row| row['id'] }).to eq([shop.id.to_s])
          expect(data['shops'].first['resourceManagers']).to include(hash_including('id' => manager.id.to_s))
          expect(data['tools'].map { |row| row['id'] }).to contain_exactly(available_tool.id.to_s, unavailable_tool.id.to_s)
          expect(data['tools']).to include(hash_including('id' => unavailable_tool.id.to_s, 'outOfService' => true))
          expect(data).not_to have_key('toolGroups')
        end
        context 'when explicitly including groups' do
          let(:include_groups) { true }
          let!(:group) { ToolGroup.create!(shop: shop, name: 'Workshop kit', reservable: true, included_tool_ids: [available_tool.id.to_s]) }
          run_test! do |response|
            expect(response.parsed_body['toolGroups']).to contain_exactly(hash_including(
              'id' => group.id.to_s, 'name' => group.name, 'targetType' => 'group',
              'includedTools' => [hash_including('id' => available_tool.id.to_s)]))
          end
        end
      end
    end
  end

  path '/tools' do
    get 'List checkout request tools, including availability' do
      parameter name: :shop_id, in: :query, required: false, schema: { type: :string }, description: 'Restrict tools to one shop while preserving membership and visibility rules. Omit or leave blank for all eligible shops.'
      tags 'Tools'
      security [sessionAuth: []]
      produces 'application/json'
      response '200', 'Checkout catalog retains out-of-service tools with their status' do
        schema type: :array, items: {
          type: :object, required: %w[id name shopId outOfService requestable], properties: {
            id: { type: :string }, name: { type: :string }, shopId: { type: :string }, shopName: { type: :string, nullable: true },
            description: { type: :string, nullable: true }, outOfService: { type: :boolean },
            open: { type: :boolean }, requestable: { type: :boolean }, allowPending: { type: :boolean },
            prerequisiteIds: { type: :array, items: { type: :string } }, prerequisiteNames: { type: :array, items: { type: :string } },
            unmetPrerequisiteIds: { type: :array, items: { type: :string } }, unmetPrerequisiteNames: { type: :array, items: { type: :string } }
          }
        }
        let!(:tool) { create(:tool, shop: shop, open: false, out_of_service: true) }
        run_test! { |response| expect(response.parsed_body).to include(hash_including('id' => tool.id.to_s, 'outOfService' => true)) }
        context 'with a shop filter' do
          let(:shop_id) { shop.id.to_s }
          let!(:other_tool) { create(:tool, shop: create(:shop), open: false) }
          let!(:hidden_tool) { create(:tool, shop: shop, disabled: true, open: false) }
          let!(:open_tool) { create(:tool, shop: shop, open: true) }
          let!(:held_tool) { create(:tool, shop: shop, open: false) }
          before { create(:tool_checkout, member: member, tool: held_tool) }
          run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to eq([tool.id.to_s]) }
          context 'for a disabled shop' do
            before { shop.update!(disabled: true) }
            run_test! { |response| expect(response.parsed_body).to eq([]) }
          end
          context 'for an unknown shop' do
            let(:shop_id) { BSON::ObjectId.new.to_s }
            run_test! { |response| expect(response.parsed_body).to eq([]) }
          end
          context 'for a pending member' do
            before { member.update!(status: 'pending'); tool.update!(allow_pending: false) }
            let!(:pending_tool) { create(:tool, shop: shop, open: false, allow_pending: true) }
            run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to eq([pending_tool.id.to_s]) }
          end
        end
        context 'without a shop filter' do
          let!(:other_tool) { create(:tool, shop: create(:shop), open: false) }
          run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to contain_exactly(tool.id.to_s, other_tool.id.to_s) }
          context 'with a blank shop filter' do
            let(:shop_id) { '' }
            run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to contain_exactly(tool.id.to_s, other_tool.id.to_s) }
          end
        end
      end
    end
  end

  path '/admin/volunteer_credits' do
    get 'List general volunteer credits excluding repair-ticket rewards' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      description 'Returns newest credits first. All credits associated with a repair ticket are excluded, including reporter rewards and reversals, regardless of optional member/status filters.'
      parameter name: :member_id, in: :query, required: false, schema: { type: :string }
      parameter name: :status, in: :query, required: false, schema: { type: :string, enum: %w[pending approved rejected reversal] }
      response '200', 'General volunteer credits only' do
        schema type: :array, items: { type: :object, required: %w[id memberId description creditValue status], properties: {
          id: { type: :string }, memberId: { type: :string }, issuedById: { type: :string, nullable: true },
          taskId: { type: :string, nullable: true }, description: { type: :string }, creditValue: { type: :number },
          status: { type: :string, enum: %w[pending approved rejected reversal] },
          discountApplied: { type: :boolean }, discountAppliedAt: { type: :string, nullable: true },
          reversed: { type: :boolean }, reversalOfId: { type: :string, nullable: true }, reversalReason: { type: :string, nullable: true },
          reversedById: { type: :string, nullable: true }, reversedAt: { type: :string, nullable: true },
          createdAt: { type: :string }, updatedAt: { type: :string },
          memberName: { type: :string, nullable: true }, issuedByName: { type: :string, nullable: true },
          taskTitle: { type: :string, nullable: true }, reversedByName: { type: :string, nullable: true }
        } }
        let!(:credit) { VolunteerCredit.create!(member_id: member.id, description: 'General volunteering') }
        let!(:reward) { VolunteerCredit.create!(member_id: member.id, description: 'Reporter reward', ticket_id: create(:fix_ticket, reporter_id: member.id).id) }
        run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to eq([credit.id.to_s]) }
        context 'with member and status filters' do
          let(:member_id) { member.id.to_s }
          let(:status) { 'pending' }
          run_test! { |response| expect(response.parsed_body.map { |row| row['id'] }).to eq([credit.id.to_s]) }
        end
      end
    end
  end
end
