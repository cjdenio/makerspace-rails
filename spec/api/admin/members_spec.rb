require 'swagger_helper'

describe 'Admin::Members API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:basic) { create(:member) }
  let(:members) { build_list(:member, 3) }

  path '/admin/members' do
    post 'Creates a member' do
      tags 'Members'
      operationId "adminCreateMember"
      consumes 'application/json'
      parameter name: :createMemberDetails, in: :body, schema: {
        title: :createMemberDetails,
        '$ref' => '#/components/schemas/NewMember'
      }, required: true

      response '200', 'member created' do
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Member'

        let(:createMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          memberContractOnFile: true,
          phone: "867-5309",
          address: {
            street: "123 Foo St",
            city: "Roswell",
            state: "NM",
            postal_code: "who knows"
          }
        }}

        run_test!
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:createMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          memberContractOnFile: true,
          phone: "867-5309",
          address: {
            street: "123 Foo St",
            city: "Roswell",
            state: "NM",
            postal_code: "who knows"
          }
        }}
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:createMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          phone: "867-5309",
          memberContractOnFile: true,
          address: {
            street: "123 Foo St",
            city: "Roswell",
            state: "NM",
            postal_code: "who knows"
          }
        }}
        run_test!
      end
    end
  end

  path "/admin/members/{id}" do
    put 'Updates a member' do
      tags 'Members'
      operationId "adminUpdateMember"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string
      parameter name: :updateMemberDetails, in: :body, schema: {
        title: :updateMemberDetails,
        '$ref' => '#/components/schemas/AdminUpdateMemberDetails'
      }, required: true

      response '200', 'member updated' do
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Member'

        let(:new_email) { "New.Email@example.com" }
        let(:member) { create(:member, email: "original@example.com") }
        let(:updateMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: new_email,
          expirationTime: Time.now.to_i * 1000,
          memberContractOnFile: true
        }}
        let(:id) { member.id }

        run_test! do
          expect(member.reload.email).to eq(new_email.downcase)
        end
      end

      response '422', 'invalid email rejected' do
        before do
          sign_in admin
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return(nil)
          passing_address = instance_double(ValidEmail2::Address, valid_strict_mx?: true)
          allow(ValidEmail2::Address).to receive(:new).and_return(passing_address)
          invalid_address = instance_double(ValidEmail2::Address, valid_strict_mx?: false)
          allow(ValidEmail2::Address).to receive(:new).with(invalid_email).and_return(invalid_address)
          allow(Resolv::DNS).to receive(:open).and_raise(Resolv::ResolvError, "NXDOMAIN")
        end

        schema '$ref' => '#/components/schemas/error'

        let(:original_email) { "original@example.com" }
        let(:invalid_email) { "person@example.invalid" }
        let(:member) { create(:member, email: original_email) }
        let(:updateMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: invalid_email,
          expirationTime: Time.now.to_i * 1000,
          memberContractOnFile: true
        }}
        let(:id) { member.id }

        run_test! do
          expect(member.reload.email).to eq(original_email)
        end
      end

      response '200', 'revocation skips email deliverability validation' do
        before do
          sign_in admin
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return(nil)
          expect(ValidEmail2::Address).not_to receive(:new)
        end

        schema '$ref' => '#/components/schemas/Member'

        let(:member) do
          build(:member, email: "current@example.invalid").tap do |member|
            member.save!(validate: false)
          end
        end
        let(:updateMemberDetails) {{
          status: "revoked",
          email: "new@example.invalid"
        }}
        let(:id) { member.id }

        run_test! do
          member.reload
          expect(member.status).to eq("revoked")
          expect(member.email).to eq("new@example.invalid")
        end
      end

      response '200', 'revocation skips email deliverability validation without an email change' do
        before do
          sign_in admin
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return(nil)
          expect(ValidEmail2::Address).not_to receive(:new)
        end

        schema '$ref' => '#/components/schemas/Member'

        let(:member) do
          build(:member, email: "current@example.invalid").tap do |member|
            member.save!(validate: false)
          end
        end
        let(:updateMemberDetails) {{
          status: "revoked"
        }}
        let(:id) { member.id }

        run_test! do
          member.reload
          expect(member.status).to eq("revoked")
          expect(member.email).to eq("current@example.invalid")
        end
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:updateMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          expirationTime: Time.now.to_i * 1000,
          memberContractOnFile: true
        }}
        let(:id) { create(:member).id }
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:updateMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          expirationTime: Time.now.to_i * 1000,
          memberContractOnFile: true
        }}
        let(:id) { create(:member).id }
        run_test!
      end

      response '404', 'Member not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:updateMemberDetails) {{
          firstname: "first",
          lastname: "last",
          email: "foo@foo.com",
          expirationTime: Time.now.to_i * 1000,
          memberContractOnFile: true
        }}
        let(:id) { 'invalid' }
        run_test!
      end
    end
  end
end