require 'rails_helper'

RSpec.describe DocumentsController, type: :controller do
  let(:member) { create(:member) }

  before do
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in member
  end

  describe "GET #show" do
    it "does not send another member's saved rental agreement" do
      other_member = create(:member)
      rental = create(:rental, member: other_member)

      expect(::Service::GoogleDrive).not_to receive(:get_document)

      get :show, params: { id: "rental_agreement", saved: "true", resource_id: rental.id }, format: :html

      expect(response).to have_http_status(403)
    end
  end
end
