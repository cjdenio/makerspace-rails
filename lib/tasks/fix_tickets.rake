namespace :fix_tickets do
  desc 'Compatibility alias for data:ensure_unique_indexes'
  task ensure_indexes: 'data:ensure_unique_indexes'
  desc 'Recover pending repair-ticket notifications; run every ten minutes'
  task recover_deliveries: :environment do
    FixTicketDeliveryRecoveryJob.perform_now
  end
end
