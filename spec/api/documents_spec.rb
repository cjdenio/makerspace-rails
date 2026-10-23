require 'swagger_helper'

describe 'Documents API', type: :request do
  let(:customer) { create(:member, customer_id: "foo") }
  let(:non_customer) { create(:member) }

  path '/documents/{id}' do 
    get 'Get a document' do 
      tags 'Documents'
      operationId 'getDocument'
      parameter name: :id, in: :path, type: :string
      parameter name: :saved, in: :query, type: :boolean, required: false
      parameter name: :resourceId, in: :query, type: :string, required: false
      parameter name: :resource_id, in: :query, type: :string, required: false
      
      response '200', 'Document found' do 
        before do
          sign_in customer
        end
        let(:id) { "code_of_conduct" }
        run_test!
      end

      # This is an HTML request so they'll just be redirected to the login page if not auth'd
      response '302', 'User not authenticated' do
        let(:id) { "code_of_conduct" }
        run_test!
      end

      response '404', 'Document not found' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'

        let(:id) { "invalid" }
        run_test!
      end

      # Regression coverage for the IDOR fixed alongside #74: any
      # authenticated member could previously request another member's
      # saved rental_agreement PDF by supplying an arbitrary resource_id.
      # These exercise the same scenario at the request/API layer rather
      # than the controller-spec layer #74 already covers.
      response '403', 'Forbidden — saved rental agreement belongs to another member' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'

        let(:other_member) { create(:member) }
        let(:rental) { create(:rental, member: other_member) }
        let(:id) { "rental_agreement" }
        let(:saved) { "true" }
        let(:resource_id) { rental.id }

        before do
          expect(::Service::GoogleDrive).not_to receive(:get_document)
        end

        run_test!
      end

      response '200', 'Saved rental agreement returned for the rental owner' do
        before { sign_in customer }

        let(:rental) { create(:rental, member: customer) }
        let(:id) { "rental_agreement" }
        let(:saved) { "true" }
        let(:resource_id) { rental.id }
        let(:fake_document) { Tempfile.new(["rental_agreement", ".pdf"]) }

        before do
          expect(::Service::GoogleDrive).to receive(:get_document).with(rental, "rental_agreement").and_return(fake_document)
        end

        run_test!
      end
    end
  end
end