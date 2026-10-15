require "swagger_helper"

RSpec.describe "Checkout requestor annotations", type: :request do
  let(:shop) { create(:shop, requestor_annotation: "Shop instructions") }
  let(:tool) { create(:tool, shop: shop) }
  let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
  let(:member) { manager }

  before do
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
    allow(GoogleResourceSyncJob).to receive(:perform_later)
  end

  annotation_schema = { type: :string, nullable: true, description: "Annotation for requestors. Null or whitespace clears the annotation; tools fall back to their shop." }
  response_schemas = {
    "shops" => { '$ref' => '#/components/schemas/Shop' },
    "tools" => { '$ref' => '#/components/schemas/Tool' }
  }
  duration_fee_schema = {
    type: :object,
    properties: {
      invoice_option_id: { type: :string }, minimum_hours: { type: :number },
      maximum_hours: { type: :number }, full_day: { type: :boolean }
    }
  }
  reservation_properties = {
    reservable: { type: :boolean }, max_concurrent_reservations: { type: :integer },
    reservation_horizon_days: { type: :integer }, minimum_advance_notice_hours: { type: :number },
    prohibit_same_day_reservations: { type: :boolean }, reservation_full_day: { type: :boolean },
    max_reservation_duration_hours: { type: :number }, reservation_requires_approval: { type: :boolean },
    reservation_prerequisite_tool_ids: { type: :array, items: { type: :string } },
    duration_fees: { type: :array, items: duration_fee_schema }
  }
  shop_properties = reservation_properties.merge(
    name: { type: :string }, requestor_annotation: annotation_schema, wiki_url: { type: :string, nullable: true },
    gdrive_id: { type: :string, nullable: true }, slack_channel: { type: :string, nullable: true },
    disabled: { type: :boolean }, color_id: { type: :string }, floor_name: { type: :string },
    capacity: { type: :integer }
  )
  %w[shops tools].each do |resource|
    path "/admin/#{resource}/{id}" do
      parameter name: :id, in: :path, type: :string
      %i[put patch].each do |verb|
        public_send(verb, "Updates #{resource.singularize} settings, including the requestor annotation") do
          tags "Checkouts"
          description "Signed-in owning-shop resource managers, admins and board members may update settings. Additional approvers use the dedicated tool annotation endpoint."
          consumes "application/json"
          produces "application/json"
          parameter name: :settings, in: :body, schema: {
            allOf: [resource == "shops" ? { type: :object, properties: shop_properties } : { '$ref' => '#/components/schemas/ToolSettingsWrite' }]
          }
          let(:id) { resource == "shops" ? shop.id.to_s : tool.id.to_s }
          let(:settings) { { requestor_annotation: " Updated instructions " } }
          response "200", "annotation saved" do
            schema response_schemas.fetch(resource)
            run_test! { |response| expect(JSON.parse(response.body)["requestorAnnotation"]).to eq("Updated instructions") }
          end
          response "403", "outside managed shop" do
            let(:member) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s]) }
            run_test!
          end
        end
      end
    end

    path "/admin/#{resource}" do
      get "Lists managed #{resource} with requestor annotations" do
        tags "Checkouts"
        description "Requires a signed-in shop manager, admin or board member. Tool lists also admit eligible additional approvers and are scoped to their assigned tools."
        produces "application/json"
        before { tool }
        response "200", "catalog" do
          schema type: :array, items: response_schemas.fetch(resource)
          run_test!
        end
      end
      post "Creates a #{resource.singularize} with an optional requestor annotation" do
        tags "Checkouts"
        description "Shop creation requires admin or board access. Tool creation also allows the owning shop's resource managers."
        consumes "application/json"
        produces "application/json"
        parameter name: :settings, in: :body, schema: {
          allOf: [resource == "shops" ? { type: :object, properties: shop_properties } : { '$ref' => '#/components/schemas/ToolSettingsWrite' }],
          required: resource == "shops" ? ["name"] : ["name", "shop_id"]
        }
        let(:member) { create(:member, :admin, :current) }
        let(:settings) { { name: "Annotated resource", shop_id: shop.id.to_s, requestor_annotation: "Instructions" } }
        response "200", "created" do
          schema response_schemas.fetch(resource)
          run_test! { |response| expect(JSON.parse(response.body)["requestorAnnotation"]).to eq("Instructions") }
        end
      end
    end
  end

  path "/shops" do
    get "Lists shops with their default checkout requestor annotations" do
      tags "Checkouts"
      description "Requires a signed-in member."
      produces "application/json"
      before { shop }
      response "200", "shops" do
        schema type: :array, items: response_schemas.fetch("shops")
        run_test!
      end
    end
  end

  path "/admin/tools/{id}/requestor_annotation" do
    parameter name: :id, in: :path, type: :string
    patch "Updates only the tool's annotation for requestors" do
      tags "Checkouts"
      description "Requires a signed-in owning-shop resource manager, admin, board member, or eligible additional approver assigned to this tool or its shop. Other tool settings cannot be changed through this endpoint."
      consumes "application/json"
      produces "application/json"
      parameter name: :settings, in: :body, schema: { type: :object, properties: { requestor_annotation: annotation_schema }, required: ["requestor_annotation"] }
      let(:id) { tool.id.to_s }
      let(:settings) { { requestor_annotation: "Tool instructions", name: "Must not change" } }
      response "200", "annotation updated" do
        schema response_schemas.fetch("tools")
        run_test! do |response|
          expect(JSON.parse(response.body)["requestorAnnotation"]).to eq("Tool instructions")
          expect(tool.reload.name).not_to eq("Must not change")
        end
        context "additional tool approver" do
          let(:member) { create(:member, :current) }
          before { CheckoutApprover.create!(member: member, tool_ids: [tool.id.to_s]) }
          run_test!
        end
        context "additional shop approver clearing an override" do
          let(:member) { create(:member, :current) }
          let(:settings) { { requestor_annotation: nil } }
          before do
            tool.update!(requestor_annotation: "Old")
            CheckoutApprover.create!(member: member, shop_ids: [shop.id.to_s])
          end
          run_test! do
            expect(tool.reload.requestor_annotation).to be_nil
            expect(tool.effective_requestor_annotation).to eq("Shop instructions")
          end
        end
      end
      response "403", "unrelated member or approver" do
        let(:member) { create(:member, :current) }
        before { CheckoutApprover.create!(member: member, tool_ids: [create(:tool).id.to_s]) }
        run_test! { expect(tool.reload.requestor_annotation).to be_nil }
      end
      response "404", "tool not found" do
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
    end
  end

  path "/admin/shops/{id}/requestor_annotation" do
    parameter name: :id, in: :path, type: :string
    patch "Updates only the shop's default annotation for requestors" do
      tags "Checkouts"
      description "Requires a signed-in owning-shop resource manager, admin or board member -- same as the full shop #update. Other shop settings cannot be changed through this endpoint. This route previously did not exist (only the equivalent tool route did), so the Shops table's \"Edit annotation\" quick-action always failed with a 404."
      consumes "application/json"
      produces "application/json"
      parameter name: :settings, in: :body, schema: { type: :object, properties: { requestor_annotation: annotation_schema }, required: ["requestor_annotation"] }
      let(:id) { shop.id.to_s }
      let(:settings) { { requestor_annotation: "Updated shop instructions", name: "Must not change" } }
      response "200", "annotation updated" do
        schema response_schemas.fetch("shops")
        run_test! do |response|
          expect(JSON.parse(response.body)["requestorAnnotation"]).to eq("Updated shop instructions")
          expect(shop.reload.name).not_to eq("Must not change")
        end
      end
      response "403", "not a manager of this shop" do
        let(:member) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s]) }
        run_test! { expect(shop.reload.requestor_annotation).to eq("Shop instructions") }
      end
      response "404", "shop not found" do
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
    end
  end
end
