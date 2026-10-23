require 'swagger_helper'

describe 'Analytics API', type: :request do
  let(:admin) { create(:member, :admin) }

  path '/admin/analytics' do
    get 'Lists analytic counts' do
      tags 'Analytics'
      operationId "adminListAnalytics"


      response '200', 'analytics read' do
        before { sign_in admin }

        schema type: :object,
          properties: {
            totalMembers: { type: :number },
            newMembers: { type: :number },
            lostMembers: { type: :number },
            subscribedMembers: { type: :number },
            pastDueInvoices: { type: :number },
            refundsPending: { type: :number },
          }

        let(:rentals) { create_list(:rental) }
        let(:members) { create_list(:member) }
        let(:invoices) { create_list(:invoice) }
        run_test!
      end
    end
  end


  path '/admin/analytics/volunteer_summary' do
    get 'Summarizes volunteer activity' do
      tags 'Analytics'
      operationId 'adminVolunteerSummary'
      produces 'application/json'
      parameter name: :year, in: :query, type: :integer, required: false,
        description: 'Calendar year applied to approved credits and completed tasks; pending credit count remains global'

      response '200', 'volunteer summary read' do
        before { sign_in admin }
        let(:year) { 2024 }

        schema type: :object,
          required: %w[credits_by_month tasks_by_month top_volunteers total_credits total_credit_value pending_credits],
          properties: {
            credits_by_month: {
              type: :array,
              items: {
                type: :object,
                required: %w[month count total_value],
                properties: {
                  month: { type: :string, pattern: '^\\d{4}-\\d{2}$' },
                  count: { type: :integer },
                  total_value: { type: :number }
                }
              }
            },
            tasks_by_month: {
              type: :array,
              items: {
                type: :object,
                required: %w[month count],
                properties: {
                  month: { type: :string, pattern: '^\\d{4}-\\d{2}$' },
                  count: { type: :integer }
                }
              }
            },
            top_volunteers: {
              type: :array,
              maxItems: 10,
              items: {
                type: :object,
                required: %w[name credits value],
                properties: {
                  name: { type: :string },
                  credits: { type: :integer },
                  value: { type: :number }
                }
              }
            },
            total_credits: { type: :integer },
            total_credit_value: { type: :number },
            pending_credits: { type: :integer }
          }

        run_test!
      end

      response '401', 'User unauthenticated' do
        let(:year) { 2024 }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
end
