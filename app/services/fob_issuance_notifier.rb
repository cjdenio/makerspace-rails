# Slack messages sent when a fob issuer (a volunteer, not admin or board) issues a
# member's first key fob: a direct message to the member and a note in the members
# relations channel, like renewal notices. Best effort: failures are logged and never
# undo the issued card.
class FobIssuanceNotifier
  def self.notify(member, issuer)
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      ::Service::SlackConnector.enque_message(
        "🔑 Your key fob has been issued by #{issuer.fullname}. Try it at the front door to make sure it works.",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("fob_issuance.member.#{member.id}")
      )
    end
    ::Service::SlackConnector.enque_message(
      "🔑 *#{member.fullname}* was issued a key fob by #{issuer.fullname} (fob issuer).",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("fob_issuance.management.#{member.id}")
    )
    true
  rescue => error
    Rails.logger.error("[FobIssuanceNotifier] member_id=#{member&.id} #{error.class}: #{error.message}")
    false
  end
end
