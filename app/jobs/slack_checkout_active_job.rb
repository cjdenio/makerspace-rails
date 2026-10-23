class SlackCheckoutActiveJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def perform(params)
    slack_user = SlackUser.find_by(slack_id: params["user_id"])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    unless member
      Service::SlackUserSync.sync_single(params["user_id"])
      slack_user = SlackUser.find_by(slack_id: params["user_id"])
      member = slack_user && Member.find_by(id: slack_user.member_id)
    end
    error = SlackCheckoutModal.membership_error(member)
    return deliver(params, error) if error
    names = [params["channel_id"], params["channel_name"], Service::SlackChannelCache.normalize_name(params["channel_name"])].compact_blank
    shop = Shop.where(:slack_channel.in => names).first
    show_all = params["text"].to_s.split(/\s+/)[1].to_s.casecmp("all").zero? || shop.nil?
    shop = nil if show_all
    rows = CheckoutInteractionQuery.new(member: member, shop: shop).listed_active_checkouts
    deliver(params, CheckoutDisplay.text(rows, include_shop: show_all))
  rescue => error
    SlackCheckoutOutcomeJob.report("active checkouts", error_class: error.class.name)
    deliver(params, "Something went wrong looking up your active checkouts. Please use the Member Portal.")
  end

  private

  def deliver(params, text)
    SlackCheckoutOutcomeJob.enqueue(text, params["response_url"], params["user_id"])
  end
end
