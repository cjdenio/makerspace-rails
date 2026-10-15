module Service
  module TestDatabaseUri
    def self.for_worker(uri, worker)
      return uri.to_s if worker.to_s.empty?

      match = /\A(mongodb(?:\+srv)?:\/\/[^\/]+\/)([^?\/#]+)(\?.*)?\z/.match(uri.to_s)
      raise ArgumentError, 'Parallel tests require MLAB_URI with an explicit database name' unless match
      raise ArgumentError, 'TEST_ENV_NUMBER must be a numeric worker suffix' unless /\A\d+\z/.match?(worker.to_s)

      "#{match[1]}#{match[2]}#{worker}#{match[3]}"
    end
  end
end
