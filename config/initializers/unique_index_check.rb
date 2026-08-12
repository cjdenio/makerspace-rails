Rails.application.config.after_initialize do
  begin
    tool_indexes = begin
      Mongoid.default_client[:tools].indexes.to_a
    rescue Mongo::Error::OperationFailure => error
      raise unless error.code == 26 # NamespaceNotFound: an empty database has no tools collection yet

      []
    end

    tool_name_index_present = tool_indexes.any? do |index|
      keys = index['key'] || index[:key] || {}
      indexed_fields = keys.keys.map(&:to_s)
      direction = keys['name'] || keys[:name]
      unique = index['unique'] || index[:unique]
      collation = index['collation'] || index[:collation] || {}

      indexed_fields == ['name'] &&
        direction == 1 &&
        unique == true &&
        collation['locale'].to_s == 'en' &&
        collation['strength'].to_i == 2
    end

    unless tool_name_index_present
      $stderr.puts <<~WARNING
        [unique-index-check] WARNING: The required unique index on tools.name is missing.
        Verify collection data and create all required unique indexes with:
          bundle exec rake data:ensure_unique_indexes
      WARNING
    end
  rescue StandardError => error
    $stderr.puts <<~WARNING
      [unique-index-check] WARNING: Unable to verify the required unique index on tools.name (#{error.class}: #{error.message}).
      Verify collection data and create all required unique indexes with:
        bundle exec rake data:ensure_unique_indexes
    WARNING
  end
end
