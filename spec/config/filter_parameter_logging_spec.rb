require 'rails_helper'

RSpec.describe "parameter log filtering" do
  it "redacts the complete Braintree webhook callback" do
    callback = {
      "bt_signature" => "merchant-id|signature-bytes",
      "bt_payload" => "base64-encoded-payload-bytes"
    }
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    expect(filter.filter(callback)).to eq(
      "bt_signature" => "[FILTERED]",
      "bt_payload" => "[FILTERED]"
    )
  end
end
