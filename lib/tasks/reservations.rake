namespace :reservations do
  desc "Rebuild today's and tomorrow's Slack reservation canvases"
  task rebuild_slack_canvases: :environment do
    Service::ReservationSlackCanvas.rebuild_all!
  end

  desc "Backfill existing Resource Managers with all current shops"
  task backfill_resource_manager_shops: :environment do
    shop_ids = Shop.all.pluck(:id).map(&:to_s)
    count = Member.where(
      role: "resource_manager",
      :resource_manager_shop_ids.exists => false
    ).update_all(resource_manager_shop_ids: shop_ids)
    puts "Backfilled #{count} legacy Resource Manager(s)"
  end

  desc "Normalize legacy reservation status spelling from canceled to cancelled"
  task normalize_cancelled_status: :environment do
    count = Reservation.where(status: "canceled").update_all(status: "cancelled")
    puts "Updated #{count} reservation(s) to cancelled"
  end
end
