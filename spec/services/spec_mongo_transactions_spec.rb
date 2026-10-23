require 'rails_helper'

RSpec.describe SpecMongoTransactions do
  it 'fails the strict policy on standalone rather than skipping examples' do
    allow(described_class).to receive(:available?).and_return(false)
    expect { described_class.verify_required!(required: true) }.to raise_error(RuntimeError, /REQUIRE_MONGO_TRANSACTIONS=true/)
  end

  it 'allows supported CI topology and optional local standalone runs' do
    allow(described_class).to receive(:available?).and_return(true)
    expect { described_class.verify_required!(required: true) }.not_to raise_error
    allow(described_class).to receive(:available?).and_return(false)
    expect { described_class.verify_required!(required: false) }.not_to raise_error
  end

  it 'does not convert connection or authentication failures into optional skips' do
    allow(described_class).to receive(:available?).and_raise(Mongo::Error, 'Connection/authentication failed')
    expect { described_class.verify_required!(required: true) }.to raise_error(Mongo::Error, 'Connection/authentication failed')
  end

  it 'skips standalone servers, even when logical sessions are available' do
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 25)).to be(false)
  end

  it 'accepts replica sets and transaction-capable sharded clusters' do
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 7, 'setName' => 'test')).to be(true)
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 8, 'msg' => 'isdbgrid')).to be(true)
  end

  it 'rejects topologies without sessions or sufficiently recent transaction support' do
    expect(described_class.supported_topology?('maxWireVersion' => 25, 'setName' => 'test')).to be(false)
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 7, 'msg' => 'isdbgrid')).to be(false)
  end
end
