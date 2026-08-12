# Use this file to easily define all of your cron jobs.
#
# It's helpful, but not entirely necessary to understand cron before proceeding.
# http://en.wikipedia.org/wiki/Cron

# Example:
#
#set :output, "dump/cron_log.log"
#
# every 2.hours do
#   command "/usr/bin/some_great_command"
#   runner "MyModel.some_method"
#   rake "some:great:rake:task"
# end
#
# every 4.days do
#   runner "AnotherModel.prune_old_records"
# end

# Learn more: http://github.com/javan/whenever

every :day, at: '2am' do
  rake "db:backup"
end

every :day, at: '7am' do
  runner "SlackProfileSyncJob.perform_later"
end

every 1.month, at: '3:15am' do
  rake "slack:refresh_public_channel_cache"
end

every 1.hour do
  runner "MemberProvisioningReconciliationJob.perform_now"
end

every '0 8 1 * *' do
  runner 'CardExpirationCheckJob.perform_later'
end
