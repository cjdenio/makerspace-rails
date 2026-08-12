namespace :members do
  desc 'Backfill local Slack and Google Drive provisioning state without changing remote access'
  task reconcile_provisioning: :environment do
    result = Service::MemberProvisioning.backfill!
    puts(
      "Member provisioning backfill complete: " \
      "Slack invited=#{result[:slack_invited]}, " \
      "Slack live=#{result[:slack_live]}, " \
      "Drive resources=#{result[:google_resources]}, " \
      "Drive transfer=#{result[:google_transfer]}"
    )
  end
end
