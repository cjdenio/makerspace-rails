require 'spec_helper'
require_relative '../../lib/service/test_database_uri'

RSpec.describe Service::TestDatabaseUri do
  it 'preserves the first worker URI unchanged' do
    uri = 'mongodb://localhost:27017/makerspace_test?replicaSet=rs0'
    expect(described_class.for_worker(uri, nil)).to eq(uri)
    expect(described_class.for_worker(uri, '')).to eq(uri)
  end

  it 'suffixes only the database and preserves query options for every worker' do
    ['', '?replicaSet=rs0', '?replicaSet=rs0&authSource=admin&retryWrites=true'].each do |query|
      uri = "mongodb://localhost:27017/makerspace_test#{query}"
      ['', '2', '3', '4'].each do |worker|
        expect(described_class.for_worker(uri, worker)).to eq("mongodb://localhost:27017/makerspace_test#{worker}#{query}")
      end
    end
  end

  it 'preserves credentials, multiple hosts and SRV URIs without resolving them' do
    ['mongodb://user:p%3Fss@host1:27017,host2:27017', 'mongodb+srv://user:password@cluster.example'].each do |base|
      expect(described_class.for_worker("#{base}/makerspace_test?authSource=admin", '2')).to eq("#{base}/makerspace_test2?authSource=admin")
    end
  end

  it 'fails clearly without leaking credentials when no database is specified' do
    ['mongodb://user:secret@localhost', 'mongodb://localhost/?replicaSet=rs0'].each do |uri|
      expect { described_class.for_worker(uri, '2') }.to raise_error(ArgumentError, 'Parallel tests require MLAB_URI with an explicit database name')
    end
  end

  it 'rejects worker suffixes that could modify URI options' do
    expect { described_class.for_worker('mongodb://localhost/makerspace_test', '?other=true') }.to raise_error(ArgumentError, /numeric worker suffix/)
  end
end
