namespace :data do
  desc "Verify and create unique indexes for core identity fields"
  task ensure_unique_indexes: :environment do
    targets = [
      [Tool, :name, { locale: 'en', strength: 2 }],
      [Shop, :name, { locale: 'en', strength: 2 }],
      [Card, :uid, nil],
      [Group, :groupName, nil],
      [Member, :email, nil],
      [Member, :customer_id, nil],
      [RentalType, :display_name, nil],
      [SlackUser, :slack_id, nil]
    ]

    targets.each do |model, field, collation|
      duplicate_pipeline = [
        {
          '$group' => {
            '_id' => "$#{field}",
            'count' => { '$sum' => 1 }
          }
        },
        { '$match' => { 'count' => { '$gt' => 1 } } }
      ]
      aggregate_options = collation ? { collation: collation } : {}
      duplicates = model.collection.aggregate(duplicate_pipeline, aggregate_options).to_a

      non_nil_duplicates = duplicates.reject { |entry| entry['_id'].nil? }
      if non_nil_duplicates.any?
        summary = non_nil_duplicates.map do |entry|
          "#{entry['_id'].inspect} (#{entry['count']} records)"
        end.join(', ')
        raise "Cannot create unique index on #{model.collection_name}.#{field}: #{summary}"
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
        puts "#{model.collection_name}.#{field}: replacing non-unique index #{index_name.inspect}"
        model.collection.indexes.drop_one(index_name)
      end

      index_options = {
        unique: true,
        partial_filter_expression: { field => { '$type' => 'string' } }
      }
      index_options[:collation] = collation if collation
      model.collection.indexes.create_one(
        { field => 1 },
        index_options
      )
      puts "#{model.collection_name}.#{field}: unique index enabled"
    end
  end
end
