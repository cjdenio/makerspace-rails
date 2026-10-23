class SlackCheckoutJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def perform(params)
    actor = find_invoker(params['user_id'])
    unless actor
      Service::SlackUserSync.sync_single(params['user_id'])
      actor = find_invoker(params['user_id'])
    end
    raise Error::Forbidden.new("You are not authorized to check out members on tools.") unless actor
    token, tool_name = params['text'].to_s.strip.split(/\s+/, 2)
    raise Error::UnprocessableEntity.new("Use /checkout @member tool-name") unless token.present? && tool_name.present?
    names = [params['channel_id'], params['channel_name'], Service::SlackChannelCache.normalize_name(params['channel_name'])].compact_blank
    shop = Shop.where(:slack_channel.in => names).first
    raise Error::UnprocessableEntity.new("No shop is configured for this channel.") unless shop
    tool = Tool.where(shop_id: shop.id).find_by(name: /\A#{Regexp.escape(tool_name)}\z/i)
    raise Error::UnprocessableEntity.new("Tool not found in this shop.") unless tool
    member = find_member_from_token(token)
    if !member && slack_mention?(token)
      Service::SlackUserSync.sync_single(token.match(/<@([^|>]+)/i)&.captures&.first)
      member = find_member_from_token(token)
    end
    raise Error::UnprocessableEntity.new("No member found. Try their Member Portal email address.") unless member
    checkout = CheckoutCreation.create!(actor_id: actor.id, member_id: member.id,
      tool_id: tool.id, shop_id: shop.id, source: "slack")
    deliver(params, "Checkout approved: #{CheckoutDisplay.escape(checkout.tool.name)} for #{CheckoutDisplay.escape(member.fullname)}.")
  rescue Error::CustomError => error
    deliver(params, error.message)
  rescue => error
    SlackCheckoutOutcomeJob.report("approval", error_class: error.class.name)
    deliver(params, "The checkout could not be completed. Check the Member Portal before trying again.")
  end

  private

  def deliver(params, message)
    SlackCheckoutOutcomeJob.enqueue(message, params['response_url'], params['user_id'])
  end

  def slack_mention?(token)
    token.start_with?('<@')
  end

  def find_member_from_token(token)
    SlackCheckoutMember.resolve(token)
  end

  def find_invoker(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    Member.find(slack_user.member_id)
  end

end
