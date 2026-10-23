# Local identity lookup for textual checkout commands. Modal requests must not
# wait for Slack identity synchronization while their trigger is expiring.
class SlackCheckoutMember
  def self.resolve(token)
    if token.start_with?('<@')
      slack_id = token.match(/<@([^|>]+)/i)&.captures&.first
      link = SlackUser.find_by(slack_id: slack_id) if slack_id
      Member.find_by(id: link.member_id) if link
    elsif token.start_with?('@')
      link = SlackUser.find_by(name: /\A#{Regexp.escape(token.delete_prefix('@'))}\z/i)
      Member.find_by(id: link.member_id) if link
    else
      Member.find_by(email: token.downcase)
    end
  end
end
