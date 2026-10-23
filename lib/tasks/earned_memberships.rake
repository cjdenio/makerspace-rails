namespace :earned_memberships do
  desc "Backfill status on legacy earned memberships created before suspend/reactivate existed"
  task backfill_status: :environment do
    count = EarnedMembership.where(:status.exists => false).update_all(status: 'active')
    puts "Backfilled #{count} legacy EarnedMembership record(s) to status: active"
  end
end
