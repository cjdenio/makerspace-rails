require 'rails_helper'
require 'timeout'

describe Counter, type: :model do
  it 'atomically increments a named sequence' do
    first_id = described_class.next_sequence_id('tickets')
    second_id = described_class.next_sequence_id('tickets')

    expect(first_id).to be_an(Integer)
    expect(second_id).to be_an(Integer)
    expect(second_id).to be > first_id
  end
  [false, true].each do |existing|
    it "allocates unique contiguous IDs across threads with #{existing ? 'an existing' : 'a new'} counter" do
      sequence = "concurrent-#{SecureRandom.hex(8)}"
      initial = existing ? described_class.next_sequence_id(sequence) : 0
      ready, start = Queue.new, Queue.new
      threads = Array.new(8) do
        Thread.new do
          ready << true
          start.pop
          Array.new(10) { described_class.next_sequence_id(sequence) }
        end
      end
      Timeout.timeout(20) { 8.times { ready.pop } }
      8.times { start << true }
      ids = Timeout.timeout(30) { threads.flat_map(&:value) }
      expect(ids.sort).to eq(((initial + 1)..(initial + 80)).to_a)
      expect(described_class.where(_id: sequence).first.seq).to eq(initial + 80)
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      threads&.each(&:join)
    end
  end

end
