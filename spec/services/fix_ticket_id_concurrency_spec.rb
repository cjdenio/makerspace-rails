require 'rails_helper'
require 'timeout'

RSpec.describe 'Concurrent repair ticket IDs', requires_transactions: true do
  before { ActiveJob::Base.queue_adapter = :test }

  [false, true].each do |existing|
    it "retries whole transactions competing for #{existing ? 'an existing' : 'a new'} sequence" do
      initial = existing ? Counter.next_sequence_id('tickets') : 0
      reporters = Array.new(4) { create(:member, :current) }
      ready, start, calls = Queue.new, Queue.new, Queue.new
      # Each reporter has a distinct write lock. Hold the first counter attempt
      # until every transaction has established its snapshot, forcing contention
      # on the counter itself. Retries must not wait on this barrier again.
      allow(Counter).to receive(:next_sequence_id).and_wrap_original do |original, name|
        calls << name
        unless Thread.current[:counter_race_started]
          Thread.current[:counter_race_started] = true
          ready << true
          start.pop
        end
        original.call(name)
      end
      threads = reporters.map do |reporter|
        Thread.new do
          FixTicketService.create!(actor: reporter, attributes: {
            title: 'Broken drill', description: 'Motor failed', category: 'broken', submission_key: SecureRandom.uuid
          })
        end
      end
      Timeout.timeout(30) { reporters.length.times { ready.pop } }
      reporters.length.times { start << true }
      tickets = Timeout.timeout(60) { threads.map(&:value) }
      ids = tickets.map(&:id)
      expect(ids).to all(be_an(Integer))
      expect(ids.sort).to eq(((initial + 1)..(initial + reporters.length)).to_a)
      expect(calls.size).to be > reporters.length
      expect(Counter.where(_id: 'tickets').first.seq).to eq(initial + reporters.length)
      expect(FixTicket.count).to eq(reporters.length)
      expect(FixTicketEvent.count).to eq(reporters.length)
      tickets.each do |ticket|
        expect(FixTicket.find(FixTicketId.mongoize("##{ticket.id}")).reporter_id).to eq(ticket.reporter_id)
        expect(FixTicketEvent.where(ticket_id: ticket.id, kind: 'created').count).to eq(1)
      end
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      threads&.each(&:join)
    end
  end
end
