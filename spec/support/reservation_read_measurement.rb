# Counts real driver commands, including cursor pagination; never stores payloads.
module ReservationReadMeasurement
  class Counter
    attr_reader :commands, :database_ms

    def initialize
      @commands = []
      @database_ms = 0.0
    end

    def started(event)
      return unless %w[find aggregate count distinct getMore].include?(event.command_name)

      collection = event.command_name == "getMore" ? event.command["collection"] : event.command[event.command_name]
      @commands << [event.command_name, collection.to_s]
    end

    def succeeded(event)
      @database_ms += event.duration * 1000 if %w[find aggregate count distinct getMore].include?(event.command_name)
    end

    def failed(_event); end
  end

  def measure_reservation_reads
    counter = Counter.new
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, counter)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    { result: result, commands: counter.commands, database_ms: counter.database_ms,
      elapsed_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 }
  ensure
    client&.unsubscribe(Mongo::Monitoring::COMMAND, counter) if counter
  end
end
