# Only capability-dependent examples are optional on standalone MongoDB.
# Connection/authentication failures and failures inside supported transactions
# remain real failures; never blanket-rescue a failing example.
module SpecMongoTransactions
  def self.verify_required!(required: ENV['REQUIRE_MONGO_TRANSACTIONS'] == 'true')
    return unless required
    return if available?

    raise 'REQUIRE_MONGO_TRANSACTIONS=true requires a transaction-capable MongoDB replica set or sharded cluster. Run bash scripts/ci/start-mongo.sh and set MLAB_URI with replicaSet=rs0.'
  end

  def self.available?
    return @available if defined?(@available)
    hello = Mongoid.default_client.database.command(hello: 1).first
    @available = supported_topology?(hello)
  end

  def self.supported_topology?(hello)
    return false unless hello['logicalSessionTimeoutMinutes']
    (hello['setName'].present? && hello['maxWireVersion'].to_i >= 7) ||
      (hello['msg'] == 'isdbgrid' && hello['maxWireVersion'].to_i >= 8)
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.before(:suite) { SpecMongoTransactions.verify_required! }
    config.prepend_before(:each, requires_transactions: true) do
      skip 'Optional: requires MongoDB transactions (replica set or supported sharded cluster)' unless SpecMongoTransactions.available?
    end
  end
end
