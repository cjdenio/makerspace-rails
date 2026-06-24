class Admin::Billing::SubscriptionsController < Admin::BillingController
  def index
    subs = ::BraintreeService::Subscription.get_subscriptions(@gateway, construct_query)
    return render_with_total_items(subs, { :each_serializer => BraintreeService::SubscriptionSerializer, adapter: :attributes })
  end

  def destroy
    subscription = ::BraintreeService::Subscription.get_subscription(@gateway, params[:id])
    ::BraintreeService::Subscription.cancel(@gateway, params[:id])

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'subscription_cancelled',
      resource_type:  'Subscription',
      resource_id:    subscription.member&.id || current_member.id,
      actor:          current_member,
      subject:        subscription.member,
      after_snapshot: { subscription_id: params[:id] },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  end

  private 
  def construct_query
    Proc.new do |search|
      unless subscription_query_params[:search].nil?
        # NOTE: Mongoid::Criteria is never nil, even when it matches zero
        # records — it's an empty enumerable. ||= can never reassign here,
        # so each fallback must check .count == 0 explicitly and reassign
        # with = , not ||=, or the chain silently never falls through and
        # the search filter gets dropped entirely (returning every
        # subscription instead of the intended match).
        resources = Member.where(subscription_id: subscription_query_params[:search])
        if resources.count == 0
          resources = Rental.where(subscription_id: subscription_query_params[:search])
        end
        if resources.count == 0
          resources = Member.search(subscription_query_params[:search])
        end
        sub_ids = resources.map(&:subscription_id).reject { |m| m.nil? }
        search.ids.in(sub_ids) unless sub_ids.empty?
      end

      unless subscription_query_params[:customer_id].nil?
        member = Member.find_by(customer_id: subscription_query_params[:customer_id])
        if member && member.subscription_id
          search.id.is(member.subscription_id)
        end
      end

      if (subscription_query_params[:end_date] && subscription_query_params[:start_date])
        search.created_at.between(subscription_query_params[:start_date], subscription_query_params[:end_date])
      elsif subscription_query_params[:start_date]
        search.created_at >= subscription_query_params[:start_date]
      elsif subscription_query_params[:end_date]
        search.created_at <= subscription_query_params[:end_date]
      end

      query_array(subscription_query_params[:subscription_status], search.status) unless subscription_query_params[:subscription_status].nil?
      query_array(subscription_query_params[:plan_id], search.plan_id) unless subscription_query_params[:plan_id].nil?
    end
  end

  def subscription_query_params
    params.permit(:start_date, :end_date, :search, :customer_id, :subscription_status => [], :plan_id => [])
  end
end