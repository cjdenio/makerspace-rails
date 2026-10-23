# Posts a reminder to the members relations Slack channel when a member who is
# billed on a household membership plan has no household yet, so an admin
# creates the household and attaches the second adult (Member profile >
# Create Household, then Manage Household > Add Secondary Member).
#
# Called at the onboarding and renewal steps: when a key fob is registered and
# when an admin renews a membership. Best effort: a failure is logged and never
# interrupts the operation that triggered it.
class HouseholdSetupReminder
  TRIGGERS = {
    fob: "a key fob was registered",
    renewal: "the membership was renewed"
  }.freeze

  def self.notify(member, trigger:)
    return false unless member&.household_setup_needed?

    base_url = Rails.configuration.x.app_base_url
    reason = TRIGGERS.fetch(trigger.to_sym, trigger.to_s)
    message = "🏠 *#{member.fullname}* is on a household membership plan but has no household yet " \
              "(#{reason}). Open their profile, choose *Create Household*, then *Manage Household* and " \
              "*Add Secondary Member* for the second adult: <#{base_url}/members/#{member.id}|Set up household>"
    ::Service::SlackConnector.enque_message(
      message,
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("household_setup_reminder.#{member.id}.#{trigger}")
    )
    true
  rescue => error
    Rails.logger.error("[HouseholdSetupReminder] member_id=#{member&.id} trigger=#{trigger} #{error.class}: #{error.message}")
    false
  end
end
