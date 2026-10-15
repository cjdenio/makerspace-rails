# Read-only, current-member data for the portal landing page.
class MemberHome
  def initialize(member)
    @member = member
  end

  def available_checkouts
    ToolCheckoutRequestEligibility.eligible_tools(member: @member)
      .reject { |tool| tool.out_of_service? || tool.shop.out_of_service? }
      .sort_by { |tool| [tool.name.casecmp?("Orientation") ? 0 : 1, tool.name.downcase, tool.id.to_s] }
      .first(10)
      .map do |tool|
        {
          id: tool.id.to_s,
          name: tool.name,
          shopName: tool.shop.name,
          requestorAnnotation: tool.effective_requestor_annotation
        }
      end
  end

  def slack
    user = @member.slack_user
    accepted = @member.provisioning_email_current? &&
      user&.slack_id.present? &&
      user.slack_email.to_s.strip.casecmp?(@member.email.to_s.strip) &&
      @member.slack_joined_at.present? && @member.slack_acceptance_pending == false

    { accepted: !!accepted, newMembersChannelUrl: accepted ? slack_channel_url : nil }
  end

  def available_volunteer_opportunities(random: Random)
    return [] unless @member.status == 'activeMember'

    # Reusable tasks are once per member; repeatable/recurring tasks can return
    # after completion, but don't recommend a second concurrent claim on Home.
    claims = VolunteerTask.where(claimed_by_id: @member.id, :parent_task_id.ne => nil,
      :status.in => %w[claimed pending completed]).pluck(:parent_task_id, :status)
    claimed_once = claims.map { |parent_id, _| parent_id.to_s }.to_set
    in_progress = claims.reject { |_, status| status == 'completed' }.map { |parent_id, _| parent_id.to_s }.to_set

    tasks = VolunteerTask.claimable.where(parent_task_id: nil).select do |task|
      already_claimed = task.status == 'reusable' ? claimed_once.include?(task.id.to_s) : in_progress.include?(task.id.to_s)
      !already_claimed && task.eligible_for?(@member)
    end
    events = VolunteerEvent.claimable_events.where(:event_date.gt => Date.today).select do |event|
      !event.attendee_ids.map(&:to_s).include?(@member.id.to_s) && event.eligible_for?(@member)
    end

    # Sample the combined eligible pool, not separate five-item lists or an
    # unfiltered shortlist that could omit otherwise available opportunities.
    (tasks + events).sample(5, random: random).map do |opportunity|
      event = opportunity.is_a?(VolunteerEvent)
      shop = opportunity.shop
      {
        id: opportunity.id.to_s,
        kind: event ? 'event' : 'task',
        title: opportunity.title,
        description: opportunity.description,
        creditValue: opportunity.credit_value,
        shopName: FixTicketPolicy.new(@member).catalog_shop_visible?(shop) ? shop.name : nil,
        eventDate: event ? opportunity.event_date.iso8601 : nil
      }
    end
  end

  private

  def slack_channel_url
    # The initializer already resolves the workspace. Never call Slack or
    # initiate provisioning from this page, including on a cache/config miss.
    team = Service::SlackConnector.slack_team_id.to_s.strip
    channel = Service::SlackConnector.new_members_channel.to_s.strip.sub(/\A#+/, "")
    return nil if team.blank? || channel.blank?

    "https://slack.com/app_redirect?#{URI.encode_www_form(team: team, channel: channel)}"
  end
end
