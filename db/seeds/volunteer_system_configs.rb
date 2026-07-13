# Run in Rails console to seed volunteer SystemConfig keys.
# Safe to re-run — skips any key already set.
#
# ENV fallback keys:
#   VOLUNTEER_CREDITS_PER_DISCOUNT
#   VOLUNTEER_MAX_DISCOUNTS_PER_YEAR
#   VOLUNTEER_DISCOUNT_AMOUNT
#   VOLUNTEER_PENDING_SLACK_CHANNEL
#   VOLUNTEER_TASK_MAX_CREDIT
#   VOLUNTEER_BOUNTY_TOKEN_ENABLED
#   VOLUNTEER_BOUNTY_TOKEN

configs = {
  'volunteer_credits_per_discount'   => '8',
  'volunteer_max_discounts_per_year' => '2',
  'volunteer_discount_amount'        => '0',     # TBD by board — set before Braintree goes live
  'volunteer_pending_slack_channel'  => 'general', # Change to your RM channel name
  'volunteer_task_max_credit'        => '2.0',
  'volunteer_bounty_token_enabled'   => 'false',
  'volunteer_bounty_token'           => '',         # Set a strong token before enabling
  'volunteer_rolling_days'            => '90',       # Rolling credit window in days
  'volunteer_leaderboard_top'         => '10',       # Number of top earners on leaderboard
}

configs.each do |key, default_value|
  existing = SystemConfig.find_by(key: key)
  if existing
    puts "SKIP #{key} — already set to '#{existing.value}'"
  else
    SystemConfig.set(key, default_value)
    puts "SET  #{key} = '#{default_value}'"
  end
end

puts "\nDone. Current volunteer settings:"
configs.keys.each { |key| puts "  #{key}: #{SystemConfig.get(key).inspect}" }
