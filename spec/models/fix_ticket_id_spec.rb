require 'rails_helper'

RSpec.describe FixTicketId do
  let(:attributes) { { reporter_id: BSON::ObjectId.new, title: 'Repair', description: 'Broken switch', category: 'broken', submission_key: SecureRandom.uuid } }

  it 'allocates integer primary keys from Ticket.pull and resolves number strings' do
    expect(Ticket).to receive(:pull).and_call_original.twice
    first = FixTicket.create!(attributes)
    second = FixTicket.create!(attributes.merge(submission_key: SecureRandom.uuid))
    expect(first.id).to be_a(Integer)
    expect(second.id).to eq(first.id + 1)
    expect(FixTicket.collection.find(_id: first.id).first['_id']).to eq(first.id)
    expect(FixTicket.find("##{first.id}")).to eq(first)
    event = FixTicketEvent.create!(ticket_id: first.id, revision: 1)
    expect(event.reload.ticket_id).to eq(first.id)
    expect(FixTicketEvent.where(ticket_id: first.id.to_s).first).to eq(event)
  end

  it 'preserves legacy ObjectId tickets and their references' do
    legacy_id = BSON::ObjectId.from_string('123456789012345678901234')
    ticket = FixTicket.create!(attributes.merge(id: legacy_id))
    event = FixTicketEvent.create!(ticket_id: legacy_id, revision: 1)
    expect(FixTicket.find(legacy_id.to_s)).to eq(ticket)
    expect(event.reload.ticket_id).to eq(legacy_id)
  end
end
