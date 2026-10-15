namespace :data do
  desc "Verify and create core unique, lookup, repair ticket, and volunteer reminder indexes"
  task ensure_unique_indexes: :environment do
    member_index_collections = %w[
      permissions
      earned_memberships
      invoices
      notes
      rentals
      payments
      cards
      mailtrap_messages
      volunteer_credits
      tool_checkouts
    ].freeze

    targets = [
      [Shortcode, :code, nil],
      [Shortcode, :target_url, nil],
      [Shop, :name, { locale: 'en', strength: 2 }],
      [Card, :uid, nil],
      [Group, :groupName, nil],
      [Invoice, :transaction_id, nil],
      [Member, :email, nil],
      [Member, :customer_id, nil],
      [RentalType, :display_name, nil],
      [SlackUser, :member_id, nil],
      [SlackUser, :slack_email, nil],
      [SlackUser, :slack_id, nil]
    ]

    targets.each do |model, field, collation|
      duplicate_pipeline = [
        ({ '$match' => { 'invalidated_at' => nil } } if model == SlackUser && %i[member_id slack_email].include?(field)),
        ({ '$match' => { 'merged_at' => nil } } if model == Member && field == :email),
        {
          '$group' => {
            '_id' => "$#{field}",
            'count' => { '$sum' => 1 }
          }
        },
        { '$match' => { 'count' => { '$gt' => 1 } } }
      ].compact
      aggregate_options = collation ? { collation: collation } : {}
      duplicates = model.collection.aggregate(duplicate_pipeline, aggregate_options).to_a

      non_nil_duplicates = duplicates.reject { |entry| entry['_id'].nil? }
      if non_nil_duplicates.any?
        summary = non_nil_duplicates.map do |entry|
          "#{entry['_id'].inspect} (#{entry['count']} records)"
        end.join(', ')
        raise "Cannot create unique index on #{model.collection_name}.#{field}: #{summary}"
      end

      if model == Shortcode && duplicates.any?
        raise "Cannot create full unique index on shortcodes.#{field}: duplicate missing/null values"
      end

      if duplicates.any?
        puts "#{model.collection_name}.#{field}: duplicate nil/missing values found; using the model's partial unique index"
      else
        puts "#{model.collection_name}.#{field}: no duplicate values found"
      end

      existing_indexes = begin
        model.collection.indexes.to_a
      rescue Mongo::Error::OperationFailure => error
        raise unless error.code == 26 # NamespaceNotFound: collection has not been created yet

        []
      end

      matching_indexes = existing_indexes.select do |index|
        keys = index['key'] || index[:key] || {}
        keys.keys.map(&:to_s) == [field.to_s] && (keys[field.to_s] || keys[field.to_sym]) == 1
      end
      existing_unique_index = matching_indexes.find do |index|
        next false unless (index['unique'] || index[:unique]) == true
        if model == Shortcode
          next false if index['partialFilterExpression'] || index[:partialFilterExpression] || index['sparse'] || index[:sparse]
        end
        if model == SlackUser && %i[member_id slack_email].include?(field)
          filter = index['partialFilterExpression'] || index[:partialFilterExpression] || {}
          expected_type = field == :member_id ? 'objectId' : 'string'
          next false unless filter == {
            field.to_s => { '$type' => expected_type },
            'invalidated_at' => nil
          }
        end
        if model == Member && field == :email
          filter = index['partialFilterExpression'] || index[:partialFilterExpression] || {}
          next false unless filter == {
            'email' => { '$type' => 'string' },
            'merged_at' => nil
          }
        end
        next true if collation.nil?

        index_collation = index['collation'] || index[:collation] || {}
        index_collation['locale'].to_s == collation[:locale] &&
          index_collation['strength'].to_i == collation[:strength]
      end

      if existing_unique_index
        index_name = existing_unique_index['name'] || existing_unique_index[:name]
        puts "#{model.collection_name}.#{field}: compatible unique index already enabled (#{index_name})"
        next
      end

      matching_indexes.each do |index|
        index_name = index['name'] || index[:name]
        puts "#{model.collection_name}.#{field}: replacing incompatible index #{index_name.inspect}"
        model.collection.indexes.drop_one(index_name)
      end

      index_options = { unique: true }
      if model == Shortcode
        # Allocation requires full uniqueness, including missing/null values.
      elsif field == :member_id || field == :slack_email
        field_type = field == :member_id ? 'objectId' : 'string'
        index_options[:partial_filter_expression] = {
          field => { '$type' => field_type },
          invalidated_at: nil
        }
      elsif model == Member && field == :email
        index_options[:partial_filter_expression] = {
          field => { '$type' => 'string' },
          merged_at: nil
        }
      else
        index_options[:partial_filter_expression] = { field => { '$type' => 'string' } }
      end
      index_options[:collation] = collation if collation
      model.collection.indexes.create_one(
        { field => 1 },
        index_options
      )
      puts "#{model.collection_name}.#{field}: unique index enabled"
    end

    # Tool names only need to be unique within a shop, not globally, so a
    # common name (e.g. "Hand Tools") can exist once per shop -- handled
    # separately from the single-field `targets` loop above since it's a
    # compound (shop_id, name) key.
    tool_collation = { locale: 'en', strength: 2 }
    tool_duplicate_pipeline = [
      { '$group' => { '_id' => { 'shop_id' => '$shop_id', 'name' => '$name' }, 'count' => { '$sum' => 1 } } },
      { '$match' => { 'count' => { '$gt' => 1 } } }
    ]
    tool_duplicates = Tool.collection.aggregate(tool_duplicate_pipeline, collation: tool_collation).to_a
    non_nil_tool_duplicates = tool_duplicates.reject { |entry| entry['_id']['name'].nil? }
    if non_nil_tool_duplicates.any?
      summary = non_nil_tool_duplicates.map { |entry| "#{entry['_id'].inspect} (#{entry['count']} records)" }.join(', ')
      raise "Cannot create unique index on tools.(shop_id, name): #{summary}"
    end

    puts tool_duplicates.any? ? "tools.(shop_id, name): duplicate nil/missing values found; using the model's partial unique index" : "tools.(shop_id, name): no duplicate values found"

    existing_tool_indexes = begin
      Tool.collection.indexes.to_a
    rescue Mongo::Error::OperationFailure => error
      raise unless error.code == 26 # NamespaceNotFound: collection has not been created yet

      []
    end

    matching_tool_indexes = existing_tool_indexes.select do |index|
      (index['key'] || index[:key] || {}).keys.map(&:to_s) == %w[shop_id name]
    end
    existing_unique_tool_index = matching_tool_indexes.find do |index|
      next false unless (index['unique'] || index[:unique]) == true

      index_collation = index['collation'] || index[:collation] || {}
      index_collation['locale'].to_s == tool_collation[:locale] && index_collation['strength'].to_i == tool_collation[:strength]
    end

    if existing_unique_tool_index
      index_name = existing_unique_tool_index['name'] || existing_unique_tool_index[:name]
      puts "tools.(shop_id, name): compatible unique index already enabled (#{index_name})"
    else
      matching_tool_indexes.each do |index|
        index_name = index['name'] || index[:name]
        puts "tools.(shop_id, name): replacing incompatible index #{index_name.inspect}"
        Tool.collection.indexes.drop_one(index_name)
      end

      # Drop the old global name-only unique index if it's still around from
      # before this was scoped per-shop -- otherwise it keeps enforcing
      # global uniqueness alongside the new compound one.
      legacy_tool_name_index = existing_tool_indexes.find do |index|
        (index['key'] || index[:key] || {}).keys.map(&:to_s) == ['name'] && (index['unique'] || index[:unique]) == true
      end
      if legacy_tool_name_index
        index_name = legacy_tool_name_index['name'] || legacy_tool_name_index[:name]
        puts "tools.name: dropping legacy global unique index #{index_name.inspect}"
        Tool.collection.indexes.drop_one(index_name)
      end

      Tool.collection.indexes.create_one(
        { shop_id: 1, name: 1 },
        unique: true,
        collation: tool_collation,
        partial_filter_expression: { name: { '$type' => 'string' } }
      )
      puts "tools.(shop_id, name): unique index enabled"
    end

    member_index_collections.each do |collection_name|
      collection = Mongoid.default_client[collection_name]
      existing_indexes = begin
        collection.indexes.to_a
      rescue Mongo::Error::OperationFailure => error
        raise unless error.code == 26 # NamespaceNotFound

        []
      end
      matching_indexes = existing_indexes.select do |index|
        keys = index['key'] || index[:key] || {}
        keys.keys.map(&:to_s) == ['member_id'] && (keys['member_id'] || keys[:member_id]) == 1
      end
      compatible_index = matching_indexes.find do |index|
        (index['unique'] || index[:unique]) != true
      end

      if compatible_index
        index_name = compatible_index['name'] || compatible_index[:name]
        puts "#{collection_name}.member_id: compatible non-unique index already enabled (#{index_name})"
        next
      end

      matching_indexes.each do |index|
        index_name = index['name'] || index[:name]
        puts "#{collection_name}.member_id: replacing unique index #{index_name.inspect}"
        collection.indexes.drop_one(index_name)
      end

      collection.indexes.create_one(member_id: 1)
      puts "#{collection_name}.member_id: non-unique index enabled"
    end

    # Install only the reminder lookup indexes. Creating every volunteer model
    # index could introduce number uniqueness on legacy records with no number.
    [
      [VolunteerTask, { status: 1, completed_at: 1 }],
      [VolunteerEvent, { status: 1, event_date: 1 }]
    ].each do |model, key|
      specification = model.index_specifications.find { |index| index.key.stringify_keys == key.stringify_keys }
      raise "Missing volunteer reminder index declaration on #{model.collection_name}: #{key}" unless specification
      raise "Volunteer reminder indexes must be nonunique" if specification.options[:unique]

      model.collection.indexes.create_one(specification.key, specification.options)
      puts "#{model.collection_name}: volunteer reminder index ensured (#{key.keys.join(', ')})"
    end

    # Keep compound uniqueness and repair lookup/outbox indexes with the same
    # release-time entry point as core indexes. MongoDB rejects duplicate data.
    [FixTicket, FixTicketEvent, FixTicketReveal, ToolGroup].each(&:create_indexes)

    # The former key treated every group target as tool_id=null, preventing
    # multiple distinct group volunteer requests. Replace it before clients opt in.
    volunteer_indexes = begin
      CheckoutApproverRequest.collection.indexes.to_a
    rescue Mongo::Error::OperationFailure => error
      raise unless error.code == 26
      []
    end
    volunteer_indexes.each do |index|
      next unless index['key'].keys.map(&:to_s) == %w[member_id tool_id status]
      CheckoutApproverRequest.collection.indexes.drop_one(index['name'])
    end

    # These constraints make the volunteer workflow's retry-safe writes
    # enforceable by MongoDB rather than relying only on application checks.
    [
      [CheckoutApproverRequest, { member_id: 1, tool_id: 1, tool_group_id: 1, status: 1 }],
      [VolunteerCredit, { tool_checkout_id: 1 }]
    ].each do |model, key|
      specification = model.index_specifications.find { |index| index.key.stringify_keys == key.stringify_keys }
      raise "Missing unique index declaration on #{model.collection_name}: #{key}" unless specification
      raise "Expected unique index on #{model.collection_name}: #{key}" unless specification.options[:unique]

      model.collection.indexes.create_one(specification.key, specification.options)
      puts "#{model.collection_name}: unique workflow index ensured (#{key.keys.join(', ')})"
    end
  end
end
