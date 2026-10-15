require 'mongo'
require 'timeout'

# CircleCI manages the sidecar, so Docker exec is unavailable in the Ruby job.
# Connect directly until rs0 has been initiated and elected a primary.
client = Mongo::Client.new(ARGV.fetch(0, 'mongodb://localhost:27017/admin?directConnection=true'),
  server_selection_timeout: 2, connect_timeout: 2, socket_timeout: 2)
begin
  Timeout.timeout(60) do
    loop do
      begin
        client.database.command(ping: 1)
        break
      rescue Mongo::Error::NoServerAvailable, Mongo::Error::SocketError
        sleep 1
      end
    end
    client.database.command(replSetInitiate: {
      _id: 'rs0', members: [{ _id: 0, host: 'localhost:27017' }]
    })
    until client.database.command(hello: 1).first['isWritablePrimary']
      sleep 1
    end
  end
  puts 'MongoDB rs0 is ready.'
rescue StandardError => error
  warn "MongoDB replica-set initialization failed: #{error.message}. Check the CircleCI MongoDB service logs."
  raise
ensure
  client.close
end
