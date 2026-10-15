desc "Runs the card-on-file expiration check.
      Run daily by the Heroku scheduler add-on; only does real work on the
      day of month configured via SystemConfig::CARD_EXPIRATION_CHECK_DAY.
      Use the admin Jobs 'Run Now' button to run on demand regardless of day."
task card_expiration_check: :environment do
  unless SystemConfig.scheduled_day_matches?(SystemConfig::CARD_EXPIRATION_CHECK_DAY)
    puts "[Card Expiration Check] Skipping -- not the configured day of month"
    next
  end

  CardExpirationCheckJob.perform_now
end
