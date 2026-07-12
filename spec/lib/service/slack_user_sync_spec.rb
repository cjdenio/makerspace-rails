require 'rails_helper'

RSpec.describe Service::SlackUserSync do
  describe '.sanitized_slack_user_attributes' do
    it 'sanitizes Slack-sourced fields before atomic persistence' do
      attributes = described_class.sanitized_slack_user_attributes(
        slack_email: 'slack@example.com',
        name: 'Alice &lt;img src=x onerror=alert(1)&gt;',
        real_name: '<b>Real & R&D</b><script>alert(1)</script>'
      )

      expect(attributes).to eq(
        slack_email: 'slack@example.com',
        name: 'Alice ',
        real_name: 'Real & R&Dalert(1)'
      )
    end
  end
end
