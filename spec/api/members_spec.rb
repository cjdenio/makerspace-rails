require 'swagger_helper'

describe 'Members API', type: :request do
  path '/members' do
    get 'Gets a list of members' do
      tags 'Members'
      operationId "listMembers"
      consumes 'application/json'
      parameter name: :pageNum, in: :query, type: :number, required: false
      parameter name: :orderBy, in: :query, type: :string, required: false
      parameter name: :order, in: :query, type: :string, required: false
      parameter name: :currentMembers, in: :query, type: :boolean, required: false
      parameter name: :search, in: :query, type: :string, required: false

      response '200', 'Members found' do
        let(:members) { create_list(:member) }
        before { sign_in create(:member, :admin) }

        schema type: :array,
            items: { '$ref' => '#/components/schemas/MemberSummary' }

        run_test!
      end

      response '401', 'User not authenciated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:member).id }
        run_test!
      end

      context 'pagination' do
        let(:items_per_page) { FastQuery::ITEMS_PER_PAGE }
        let(:total_items) { (items_per_page * 2) + 6 }

        before do
          create_list(:member, total_items - 1)
          sign_in create(:member, :admin)
        end

        it 'returns only one page while preserving the total item count' do
          get '/api/members', params: {
            pageNum: 0,
            orderBy: '',
            order: 'asc',
            currentMembers: false
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body).length).to eq(items_per_page)
          expect(response.headers['total-items'].to_i).to eq(total_items)
        end

        it 'returns the next page for pageNum 1' do
          get '/api/members', params: {
            pageNum: 1,
            orderBy: '',
            order: 'asc',
            currentMembers: false
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body).length).to eq(items_per_page)
          expect(response.headers['total-items'].to_i).to eq(total_items)
        end

        it 'returns the final partial page for pageNum 2' do
          get '/api/members', params: {
            pageNum: 2,
            orderBy: '',
            order: 'asc',
            currentMembers: false
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body).length).to eq(6)
          expect(response.headers['total-items'].to_i).to eq(total_items)
        end
      end
    end
  end

  path '/members/{id}' do
    get 'Gets a member' do
      tags 'Members'
      operationId "getMember"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string

      response '200', 'Member found' do
        let(:current_member) { create(:member) }
        before { sign_in current_member }
        let(:id) { current_member.id }

        schema '$ref' => '#/components/schemas/Member'

        run_test!
      end

      response '404', 'Member not found' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { 'invalid' }
        run_test!
      end

      response '401', 'User not authenciated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:member).id }
        run_test!
      end
    end

    put 'Updates a member and uploads signature' do
      tags 'Members'
      operationId "updateMember"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string
      parameter name: :updateMemberDetails, in: :body, schema: {
        title: :updateMemberDetails,
        type: :object,
        # TODO: This should use oneOf for signature/member partial
        properties: {
          firstname: { type: :string },
          lastname: { type: :string },
          email: { type: :string },
          memberContractOnFile: { type: :boolean },
          silenceEmails: { type: :boolean },
          phone: { type: :string },
          address: {
            type: :object,
            properties: {
              street: { type: :string },
              unit: { type: :string },
              city: { type: :string },
              state: { type: :string },
              postalCode: { type: :string },
            }
          },
          signature: { type: :string },
        },
      }, required: true

      # Update object
      let(:updateMemberDetails) {{ firstname: "new firstname", lastname: "new lastname", email: "foo@foo.com" }}

      response '200', 'member updated' do
        let(:current_member) { create(:member) }
        before { sign_in current_member }

        schema '$ref' => '#/components/schemas/Member'

        let(:id) { current_member.id }
        run_test!
      end

      response '200', 'Signature upload' do
        let(:current_member) { create(:member) }
        before { sign_in current_member }

        let(:updateMemberDetails) {{ signature: "foobar.png" }}

        schema '$ref' => '#/components/schemas/Member'

        let(:id) { current_member.id }
        run_test!
      end

      response '403', 'Forbidden updating different member' do
        let(:current_member) { create(:member) }
        before { sign_in current_member }

        schema '$ref' => '#/components/schemas/error'

        let(:other_user) { create(:member) }
        let(:id) { other_user.id }
        run_test!
      end

      response '401', 'User not authenciated or authorized' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:member).id }
        run_test!
      end

      response '404', 'member not found' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'

        let(:id) { 'invalid' }
        run_test!
      end
    end

    # NOTE: All routes for this resource are mounted under scope :api in
    # routes.rb (servers: [{ url: '/api' }] in swagger_helper.rb). Rswag's
    # run_test! prepends this automatically when building requests from the
    # `path` declaration above, but these plain `it` blocks build requests
    # manually and must include the /api prefix themselves — its absence
    # was the actual cause of the 404s seen here (confirmed via local run).
    context 'when updating email for the logged-in member' do
      let(:current_member) { create(:member, email: 'current@example.com') }
      let(:id) { current_member.id }

      before { sign_in current_member }

      it 'normalizes and persists a valid new email' do
        put "/api/members/#{id}", params: { email: '  New.Email@Example.COM  ' }, as: :json

        expect(response).to have_http_status(:ok)
        expect(current_member.reload.email).to eq('new.email@example.com')
      end

      it 'invokes EmailDeliverabilityValidator against the new submitted email value' do
        new_email = 'new-submitted@example.com'

        expect_any_instance_of(EmailDeliverabilityValidator)
          .to receive(:validate_each)
          .with(instance_of(Member), :email, new_email)
          .and_call_original

        put "/api/members/#{id}", params: { email: new_email }, as: :json

        expect(response).to have_http_status(:ok)
      end

      it 'returns an error response for an undeliverable new email and leaves the previous email persisted' do
        previous_email = current_member.email
        undeliverable_email = 'undeliverable@example.invalid'

        allow_any_instance_of(EmailDeliverabilityValidator).to receive(:validate_each) do |_validator, record, attribute, value|
          record.errors.add(attribute, EmailDeliverabilityValidator::UNDELIVERABLE_MESSAGE) if value == undeliverable_email
        end

        put "/api/members/#{id}", params: { email: undeliverable_email }, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(current_member.reload.email).to eq(previous_email)
      end
    end
  end
end
