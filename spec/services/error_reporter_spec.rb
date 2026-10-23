require 'rails_helper'

RSpec.describe Service::ErrorReporter do
  describe '.notify' do
    it 'logs an exception before notifying Honeybadger' do
      error = StandardError.new('remote service unavailable')
      context = { member_id: '123' }

      expect(Rails.logger).to receive(:error).with(
        a_string_including('[ErrorReporter] StandardError: remote service unavailable', 'member_id', '123')
      ).ordered
      expect(Honeybadger).to receive(:notify).with(error, context: context).ordered

      described_class.notify(error, context: context)
    end

    it 'logs string error descriptions' do
      allow(Honeybadger).to receive(:notify)

      expect(Rails.logger).to receive(:error).with('[ErrorReporter] scheduled task failed')

      described_class.notify('scheduled task failed')
    end

    it 'redacts webhook credentials from logged context without changing Honeybadger context' do
      response_url = 'https://hooks.slack.com/actions/T123/B456/secret'
      context = {
        response_url: response_url,
        delivery: { 'webhook_url' => response_url },
        member_id: '123'
      }

      expect(Rails.logger).to receive(:error) do |message|
        expect(message).to include('response_url', 'webhook_url', 'member_id', '123')
        expect(message.scan('[FILTERED]').size).to eq(2)
        expect(message).not_to include(response_url)
      end.ordered
      expect(Honeybadger).to receive(:notify).with('Slack response failed', context: context).ordered

      described_class.notify('Slack response failed', context: context)
    end

    it 'applies the configured request parameter filters to logged context' do
      context = {
        params: {
          email: 'member@example.com',
          password: 'correct horse battery staple',
          payment_method_token: 'payment-token'
        }
      }

      expect(Rails.logger).to receive(:error) do |message|
        expect(message).to include('member@example.com')
        expect(message.scan('[FILTERED]').size).to eq(2)
        expect(message).not_to include('correct horse battery staple', 'payment-token')
      end.ordered
      expect(Honeybadger).to receive(:notify).with('Request failed', context: context).ordered

      described_class.notify('Request failed', context: context)
    end
  end
end
