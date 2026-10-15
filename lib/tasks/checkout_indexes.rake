namespace :data do
  desc "Create only the nonunique indexes used by checkout list queries (no index replacement)"
  task ensure_checkout_indexes: :environment do
    targets = [
      [Member, { status: 1, expirationTime: 1 }],
      [ToolCheckout, { member_id: 1, revoked_at: 1, tool_id: 1 }],
      [CheckoutApprover, { member_id: 1 }],
      [ToolCheckoutRequest, { member_id: 1, status: 1, request_date: 1, _id: 1 }],
      [ToolCheckoutRequest, { tool_id: 1, status: 1, request_date: 1, _id: 1 }],
      [ToolCheckoutRequest, { tool_group_id: 1, status: 1 }],
      [Tool, { shop_id: 1, name: 1, _id: 1, disabled: 1, open: 1 }]
    ]

    targets.each do |model, key|
      specification = model.index_specifications.find { |index| index.key.stringify_keys == key.stringify_keys }
      raise "Missing checkout index declaration on #{model.collection_name}: #{key}" unless specification
      raise "Checkout performance indexes must be nonunique" if specification.options[:unique]

      # Do not call model.create_indexes: identity indexes on the same model
      # may require a separate migration of legacy index options.
      model.collection.indexes.create_one(specification.key, specification.options)
      puts "#{model.collection_name}: checkout index ensured (#{key.keys.join(', ')})"
    end
  end
end
