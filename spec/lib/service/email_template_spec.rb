require 'rails_helper'

RSpec.describe Service::EmailTemplate do
  describe '.sanitize_template_value' do
    it 'sanitizes ASCII-8BIT encoded replacement values' do
      value = "<b>Jo\u0301</b><script>alert(1)</script>".dup.force_encoding(Encoding::ASCII_8BIT)

      expect { described_class.send(:sanitize_template_value, value) }.not_to raise_error
      expect(described_class.send(:sanitize_template_value, value)).to eq("<b>Jó</b>alert(1)")
    end
  end
end
