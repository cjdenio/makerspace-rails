require 'rails_helper'

RSpec.describe CheckoutMailer, type: :mailer do
  let(:primary) { create(:member, :current) }
  let(:member) { create(:member, :current, groupName: primary.id.to_s) }
  let(:rows) { [{ name: 'Bandsaw', shop: 'Woodshop', expires_on: '2026-10-22', training_url: 'https://example.com/training' }] }
  before { allow(CheckoutExpirationNotice).to receive(:portal_url).and_return('https://example.com/tool-checkouts?mode=self-service') }

  it 'sends multipart notices directly to a secondary household member' do
    mail = described_class.expiration_notice(member.id.to_s, rows, 'upcoming')
    expect(mail.to).to eq([member.email])
    expect(mail.perform_deliveries).to be true
    expect(mail.subject).to eq('Manchester Makerspace — Your tool checkouts expire soon')
    expect(mail.html_part.body.decoded).to include('Bandsaw', 'Woodshop', '2026-10-22', 'https://example.com/training')
    expect(mail.text_part.body.decoded).to include('Bandsaw', 'https://example.com/tool-checkouts?mode=self-service')
  end

  it 'uses the expired subject and keeps revoked member suppression' do
    member.set(status: 'revoked')
    mail = described_class.expiration_notice(member.id.to_s, rows, 'expired')
    expect(mail.subject).to eq('Manchester Makerspace — Your tool checkouts have expired')
    expect(mail.perform_deliveries).to be false
  end
end
