class SlackCheckoutRequestJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def perform(params)
    @slack_user_id = params['user_id']
    response_url     = params['response_url']
    channel_name     = params['channel_name']
    channel_id       = params['channel_id']
    invoker_slack_id = params['user_id']
    tool_name        = params['tool_name'].to_s.strip.presence

    invoker = find_member(invoker_slack_id)
    if invoker.nil?
      synced_member = Service::SlackUserSync.sync_single(invoker_slack_id)
      invoker = find_member(invoker_slack_id) if synced_member
    end

    unless invoker
      post_response(response_url, :ephemeral, "Link your Slack account to a Member Portal account before using `/checkout request`.")
      return
    end

    channel_names = [
      channel_id,
      channel_name,
      Service::SlackChannelCache.normalize_name(channel_name)
    ].compact_blank.uniq
    shop = Shop.where(:slack_channel.in => channel_names).first
    unless shop
      post_response(response_url, :ephemeral, "No shop is configured for ##{channel_name}. Run `/checkout request` from a shop channel.")
      return
    end

    return list_eligible_tools(response_url, invoker, shop) if tool_name.nil?

    tool = Tool.where(shop_id: shop.id).find_by(name: /\A#{Regexp.escape(tool_name)}\z/i)
    tool ||= ToolGroup.where(shop_id: shop.id, archived: false).find_by(name: /\A#{Regexp.escape(tool_name)}\z/i)
    unless tool
      tool_list = ToolCheckoutRequestEligibility.eligible_tools(member: invoker, shop: shop).map(&:name).join(', ')
      post_response(response_url, :ephemeral, "No eligible tool matching '#{tool_name}' in #{shop.name}. Available: #{tool_list.presence || 'none'}")
      return
    end

    create_request(response_url, invoker, tool)
  rescue => e
    SlackCheckoutOutcomeJob.report("request", error_class: e.class.name)
    post_response(response_url, :ephemeral, 'Something went wrong processing your request. Please try again or use the Member Portal.')
  end

  private

  def find_member(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    Member.find(slack_user.member_id)
  end

  def list_eligible_tools(response_url, invoker, shop)
    tools = ToolCheckoutRequestEligibility.eligible_tools(member: invoker, shop: shop)
    tools += CheckoutInteractionQuery.new(member: invoker, shop: shop).requestable_groups
    if tools.empty?
      post_response(response_url, :ephemeral, "No eligible tools found in #{shop.name}. Your membership must be active (or, if pending, the tool must allow pending members) before requesting a checkout.")
      return
    end

    lines = tools.map { |tool| "• #{tool.is_a?(ToolGroup) ? ':linked_paperclips: ' : ''}#{tool.name}" }
    post_response(response_url, :ephemeral, "*Eligible tools:*\n#{lines.join("\n")}\n\nUse `/checkout request <tool name>` to request one.")
  end

  def create_request(response_url, invoker, tool)
    if tool.is_a?(ToolGroup)
      ToolGroupCheckout.request!(member: invoker, group: tool)
    else
    CheckoutRequestCreation.create!(member_id: invoker.id, tool_id: tool.id, shop_id: tool.shop_id)
    end
    post_response(response_url, :ephemeral, "Requested checkout on #{CheckoutDisplay.escape(tool.name)}. An approver will be notified.")
  rescue Error::CustomError => error
    post_response(response_url, :ephemeral, error.message)
  end

  def post_response(response_url, _response_type, text)
    SlackCheckoutOutcomeJob.enqueue(text, response_url, @slack_user_id)
  end
end
