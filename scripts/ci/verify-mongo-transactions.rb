require 'mongo'
require_relative '../../lib/service/database_safety'

# This probe runs before RSpec/E2E, independently of Rails and example metadata.
# DatabaseSafety uses ActiveSupport string helpers.
require 'active_support/core_ext/object/blank'
Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'CI transaction probe')
client = Mongo::Client.new(ENV.fetch('MLAB_URI'), server_selection_timeout: 10)
collection = client[:ci_transaction_probe]
probe_id = BSON::ObjectId.new
begin
  collection.insert_one(_id: probe_id, value: 'before')
  client.start_session do |session|
    session.with_transaction do
      collection.find(_id: probe_id).update_one({ '$set' => { value: 'committed' } }, session: session)
    end
    raise 'MongoDB transaction commit verification failed' unless collection.find(_id: probe_id).first['value'] == 'committed'

    session.start_transaction
    begin
      collection.find(_id: probe_id).update_one({ '$set' => { value: 'aborted' } }, session: session)
    ensure
      session.abort_transaction
    end
    raise 'MongoDB transaction rollback verification failed' unless collection.find(_id: probe_id).first['value'] == 'committed'
  end
  puts 'MongoDB transaction commit and rollback verified.'
ensure
  collection.find(_id: probe_id).delete_one
  client.close
end
