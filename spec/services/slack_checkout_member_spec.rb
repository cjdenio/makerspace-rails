require 'rails_helper'

RSpec.describe SlackCheckoutMember do
  it 'resolves linked mentions, usernames and email locally' do
    member = create(:member, :current)
    SlackUser.create!(member: member, slack_id: 'UTARGET', name: 'test.user')
    expect(Service::SlackUserSync).not_to receive(:sync_single)
    ['<@UTARGET>', '<@UTARGET|name>', '@TEST.USER', member.email.upcase].each do |token|
      expect(described_class.resolve(token)).to eq(member)
    end
    ['<@UNKNOWN>', '<@', '@testXuser', 'unknown@example.test'].each do |token|
      expect(described_class.resolve(token)).to be_nil
    end
  end
end
