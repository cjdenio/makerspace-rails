desc "Clean up old invoicing redis keys.
      Run daily by the Heroku scheduler add-on; only does real work on the
      day of month configured via SystemConfig::GARBAGE_COLLECT_DAY.
      Use the admin Jobs 'Run Now' button to run on demand regardless of day."
task :gc => :environment do
  unless SystemConfig.scheduled_day_matches?(SystemConfig::GARBAGE_COLLECT_DAY)
    puts "[Garbage Collector] Skipping -- not the configured day of month"
    next
  end

  GarbageCollectJob.perform_now
end
