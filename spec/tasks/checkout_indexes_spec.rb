require 'rails_helper'
require 'rake'

RSpec.describe 'data:ensure_checkout_indexes' do
  let(:task) { Rake::Task['data:ensure_checkout_indexes'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('data:ensure_checkout_indexes')
    task.reenable
    reset_index_test_collections
  end

  after do
    # DatabaseCleaner's deletion strategy preserves indexes. Remove this spec's
    # deliberately incompatible indexes even when an example fails, so they
    # cannot enforce uniqueness on unrelated specs' member fixtures.
    reset_index_test_collections
  end

  def reset_index_test_collections
    Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'Checkout index test collection reset')
    [Card, Member, ToolCheckout, CheckoutApprover, ToolCheckoutRequest, Tool].each { |model| model.collection.drop }
  end

  it 'creates only checkout indexes despite legacy identity indexes and is repeatable' do
    Card.collection.indexes.create_one({ uid: 1 }, unique: true, background: true)
    Member.collection.indexes.create_one({ email: 1 }, unique: true)
    Card.collection.insert_one(uid: 'legacy-card')
    card_indexes = Card.collection.indexes.to_a
    email_index = Member.collection.indexes.to_a.find { |index| index['name'] == 'email_1' }
    expect { Card.create_indexes }.to raise_error(Mongo::Error::OperationFailure, /uid_1/)

    2.times do
      task.reenable
      expect { task.invoke }.not_to raise_error
    end

    {
      Member => { 'status' => 1, 'expirationTime' => 1 },
      ToolCheckout => { 'member_id' => 1, 'revoked_at' => 1, 'tool_id' => 1 },
      CheckoutApprover => { 'member_id' => 1 }
    }.each do |model, key|
      matches = model.collection.indexes.to_a.select { |index| index['key'] == key }
      expect(matches.length).to eq(1)
      expect(matches.first['unique']).not_to eq(true)
    end
    [
      [ToolCheckoutRequest, { 'member_id' => 1, 'status' => 1, 'request_date' => 1, '_id' => 1 }],
      [ToolCheckoutRequest, { 'tool_id' => 1, 'status' => 1, 'request_date' => 1, '_id' => 1 }],
      [ToolCheckoutRequest, { 'tool_group_id' => 1, 'status' => 1 }],
      [Tool, { 'shop_id' => 1, 'name' => 1, '_id' => 1, 'disabled' => 1, 'open' => 1 }]
    ].each do |model, key|
      matches = model.collection.indexes.to_a.select { |index| index['key'] == key }
      expect(matches.length).to eq(1)
      expect(matches.first['unique']).not_to eq(true)
      expect(matches.first.dig('collation', 'strength')).to eq(2) if model == Tool
    end
    expect(Card.collection.indexes.to_a).to eq(card_indexes)
    expect(Card.collection.find(uid: 'legacy-card').count).to eq(1)
    expect(Member.collection.indexes.to_a.find { |index| index['name'] == 'email_1' }).to eq(email_index)
    expect(Member.collection.indexes.to_a.length).to eq(3) # _id, existing email, new checkout filter
  end

  it 'stops on a targeted index conflict without dropping the existing index' do
    Member.collection.indexes.create_one({ status: 1, expirationTime: 1 }, unique: true)
    indexes_before = Member.collection.indexes.to_a
    expect { task.invoke }.to raise_error(Mongo::Error::OperationFailure)
    expect(Member.collection.indexes.to_a).to eq(indexes_before)
  end
end
