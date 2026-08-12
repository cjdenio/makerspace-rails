require 'rails_helper'

class ValidatorEmailDeliverabilityModel
  include ActiveModel::Model
  include ActiveModel::Validations

  attr_accessor :email

  validates :email, email_deliverability: true
end

RSpec.describe EmailDeliverabilityValidator do
  subject(:model) { ValidatorEmailDeliverabilityModel.new(email: email) }

  before do
    allow(ENV).to receive(:[]).and_call_original
  end

  context "when SKIP_EMAILVALIDATION is set" do
    let(:email) { "bad@example.invalid" }

    it "skips deliverability checks and accepts the email" do
      allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return("true")
      expect(ValidEmail2::Address).not_to receive(:new)

      expect(model).to be_valid
    end
  end

  context "when SKIP_EMAILVALIDATION is not set" do
    let(:email) { "test@example.com" }

    it "runs deliverability checks and accepts a deliverable email" do
      allow(ENV).to receive(:[]).with("SKIP_EMAILVALIDATION").and_return(nil)
      address = instance_double(ValidEmail2::Address, valid_strict_mx?: true)
      expect(ValidEmail2::Address).to receive(:new).with(email).and_return(address)

      expect(model).to be_valid
    end
  end
end
