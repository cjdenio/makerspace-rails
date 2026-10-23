require 'rails_helper'

RSpec.describe 'Tool unique index startup check' do
  def run_check(indexes)
    RSpec::Mocks.with_temporary_scope do
      client = double('client')
      allow(client).to receive(:[]).with(:tools).and_return(double(indexes: indexes))
      allow(Mongoid).to receive(:default_client).and_return(client)
      allow(Rails.application.config).to receive(:after_initialize).and_yield
      load Rails.root.join('config/initializers/unique_index_check.rb')
    end
  end

  it 'accepts the case-insensitive per-shop unique index' do
    indexes = [{ 'key' => { 'shop_id' => 1, 'name' => 1 }, 'unique' => true,
                 'collation' => { 'locale' => 'en', 'strength' => 2 } }]
    expect { run_check(indexes) }.not_to output.to_stderr
  end

  it 'does not mistake the legacy global name index for the required per-shop index' do
    indexes = [{ 'key' => { 'name' => 1 }, 'unique' => true,
                 'collation' => { 'locale' => 'en', 'strength' => 2 } }]
    expect { run_check(indexes) }.to output(/tools\.\(shop_id, name\) is missing/).to_stderr
  end
end
