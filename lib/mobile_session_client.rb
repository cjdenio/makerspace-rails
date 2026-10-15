# Phone classification is deliberately conservative. A narrow desktop window,
# tablet, or unknown user agent must retain ordinary session behavior.
module MobileSessionClient
  def self.phone?(user_agent)
    agent = user_agent.to_s
    return false if agent.match?(/iPad|Tablet/i)

    agent.match?(/iPhone/i) || (agent.match?(/Android/i) && agent.match?(/Mobile/i))
  end
end
