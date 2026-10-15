require 'rails_helper'

RSpec.describe Service::DatabaseSafety do
  it 'allows destructive operations for a recognized test database URI' do
    expect(
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://database.example.com/makerspace_test'
      )
    ).to be(true)
  end

  it 'allows destructive operations when the username identifies a test account' do
    expect(
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://test_runner:secret@database.example.com/makerspace'
      )
    ).to be(true)
  end

  it 'allows destructive operations when the hostname identifies a test server' do
    expect(
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://production@dev-test.example.com/makerspace'
      )
    ).to be(true)
  end

  it 'does not trust dev or test in the password or query string' do
    unsafe_uris = [
      'mongodb://production:dev-password@database.example.com/makerspace',
      'mongodb://production@database.example.com/makerspace?label=test'
    ]

    unsafe_uris.each do |mlab_uri|
      expect do
        described_class.ensure_safe_mlab_uri!(operation: 'test reset', mlab_uri: mlab_uri)
      end.to raise_error(RuntimeError, /Refusing to run test reset/)
    end
  end

  it 'refuses malformed database URIs' do
    expect do
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'not a mongodb URI with test in it'
      )
    end.to raise_error(RuntimeError, /Refusing to run test reset/)
  end

  it 'refuses destructive operations for an unrecognized database URI' do
    expect do
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://database.example.com/makerspace'
      )
    end.to raise_error(RuntimeError, /Refusing to run test reset/)
  end

  it 'refuses destructive operations when MLAB_URI is absent' do
    expect do
      described_class.ensure_safe_mlab_uri!(operation: 'test reset', mlab_uri: nil)
    end.to raise_error(RuntimeError, /MLAB_URI is not set/)
  end
end
