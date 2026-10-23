desc 'Send due grouped checkout expiration warnings and final notices'
task checkout_expiration_notice: :environment do
  CheckoutExpirationNoticeJob.perform_now
end

namespace :data do
  desc 'Ensure the checkout expiration query index without changing checkout dates'
  task ensure_checkout_expiration_indexes: :environment do
    ToolCheckout.collection.indexes.create_one(
      { revoked_at: 1, superseded_by_id: 1, expires_on: 1, member_id: 1 })
  end
end
