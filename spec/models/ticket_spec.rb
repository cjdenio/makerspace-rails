require 'rails_helper'

describe Ticket, type: :model do
  describe '.pull' do
    it 'returns the next ticket number' do
      allow(Counter).to receive(:next_sequence_id).with('tickets').and_return(42)

      expect(described_class.pull).to eq(42)
    end
  end
end
