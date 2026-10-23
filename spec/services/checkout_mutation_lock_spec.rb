require 'rails_helper'

RSpec.describe CheckoutMutationLock do
  # Deterministic Redis lease semantics, without sleeping or touching shared keys.
  let(:entries) { {} }
  let(:clock) { [0] }
  before do
    allow(REDIS).to receive(:set) do |key, token, **options|
      entry = entries[key]
      entries.delete(key) if entry && entry[:until] && entry[:until] <= clock[0]
      next false if entries.key?(key)
      entries[key] = { token: token, until: options[:ex] && clock[0] + options[:ex] }
      true
    end
    allow(REDIS).to receive(:get) { |key| entries.dig(key, :token) }
    allow(REDIS).to receive(:eval) do |_script, keys:, argv:|
      entries.delete(keys.first) if entries.dig(keys.first, :token) == argv.first
    end
  end

  it 'keeps the shared catalog key owned after multiple ordinary lease periods' do
    CatalogMutationLock.with_persistent('shop') do |assert_owned|
      clock[0] += 300
      assert_owned.call
      expect { CatalogMutationLock.with(['shop']) { raise 'must not enter' } }
        .to raise_error(Error::UnprocessableEntity)
      expect { CatalogMutationLock.with_persistent('shop') { raise 'must not enter' } }
        .to raise_error(Error::UnprocessableEntity)
    end
    expect(entries).to be_empty
    expect { CatalogMutationLock.with(['shop']) {} }.not_to raise_error
  end

  it 'releases ownership on exceptions without removing a replacement owner' do
    expect do
      CatalogMutationLock.with_persistent('shop') { raise 'transaction failed' }
    end.to raise_error('transaction failed')
    expect(entries).to be_empty
    CatalogMutationLock.with_persistent('shop') do |assert_owned|
      entries['checkout_request_lock/catalog/shop'] = { token: 'replacement' }
      expect { assert_owned.call }.to raise_error(Error::Conflict)
    end
    expect(entries['checkout_request_lock/catalog/shop'][:token]).to eq('replacement')
  end
end
