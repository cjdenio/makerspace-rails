require 'rails_helper'
require 'rake'

RSpec.describe 'data:ensure_unique_indexes' do
  let(:task) { Rake::Task['data:ensure_unique_indexes'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('data:ensure_unique_indexes')
    task.reenable
    Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'SlackUser test collection drop')

    begin
      SlackUser.collection.drop
    rescue Mongo::Error::OperationFailure => error
      raise unless error.code == 26
    end
  end

  after do
    task.reenable
  end

  it 'creates the unique index when the target collection does not exist' do
    expect(SlackUser.collection.database.collection_names).not_to include(SlackUser.collection_name)

    expect { task.invoke }.not_to raise_error

    slack_id_index = SlackUser.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['slack_id']
    end
    expect(slack_id_index).to include('unique' => true)
  end

  it 'creates and recognizes a case-insensitive unique tool-name index' do
    Tool.delete_all

    expect { task.invoke }.not_to raise_error

    tool_name_index = Tool.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['name']
    end
    expect(tool_name_index).to include('unique' => true)
    expect(tool_name_index.fetch('collation')).to include('locale' => 'en', 'strength' => 2)

    Tool.collection.insert_one(name: 'Lathe')
    expect do
      Tool.collection.insert_one(name: 'lathe')
    end.to raise_error(Mongo::Error::OperationFailure, /duplicate key/i)
  end

  it 'rejects tool names that differ only by case before creating the index' do
    Tool.delete_all
    existing_index = Tool.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['name']
    end
    Tool.collection.indexes.drop_one(existing_index.fetch('name')) if existing_index
    Tool.collection.insert_many([{ name: 'Lathe' }, { name: 'lathe' }])

    expect { task.invoke }.to raise_error(
      RuntimeError,
      /Cannot create unique index on tools.name.*Lathe.*records/i
    )
  ensure
    Tool.collection.delete_many({})
    task.reenable
    task.invoke
  end

  it 'creates a case-insensitive unique shop-name index' do
    Shop.delete_all

    expect { task.invoke }.not_to raise_error

    shop_name_index = Shop.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['name']
    end
    expect(shop_name_index).to include('unique' => true)
    expect(shop_name_index.fetch('collation')).to include('locale' => 'en', 'strength' => 2)

    Shop.collection.insert_one(name: 'Woodshop')
    expect do
      Shop.collection.insert_one(name: 'woodshop')
    end.to raise_error(Mongo::Error::OperationFailure, /duplicate key/i)
  end

  it 'creates a partial unique member customer-id index that permits nil values' do
    expect { task.invoke }.not_to raise_error

    customer_id_index = Member.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['customer_id']
    end
    expect(customer_id_index).to include('unique' => true)
    expect(customer_id_index.fetch('partialFilterExpression')).to eq(
      'customer_id' => { '$type' => 'string' }
    )

    inserted_ids = Member.collection.insert_many([
      { customer_id: nil },
      { customer_id: nil }
    ]).inserted_ids
    expect(inserted_ids.length).to eq(2)
  ensure
    Member.collection.delete_many('_id' => { '$in' => inserted_ids }) if inserted_ids.present?
  end
end
