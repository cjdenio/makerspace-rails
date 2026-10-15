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

  def cancellation_impact
    subscription = ::BraintreeService::Subscription.get_subscription(@gateway, params[:id])
    reservations = ReservationLifecycleService.cancellation_impact(subscription.resource)
    render json: {
      reservationCount: reservations.length,
      membershipExpiresAt: membership_expiration_for(subscription.resource)&.iso8601,
      reservations: reservations.map do |reservation|
        {
          id: reservation.id.to_s,
          title: reservation.title,
          calendarHtmlLink: reservation.calendar_html_link,
          startAt: reservation.start_at.iso8601,
          endAt: reservation.end_at.iso8601
        }
      end
    }
  end

  private 
  def membership_expiration_for(resource)
    case resource
    when Member
      resource.membership_expires_at
    when Group
      return nil if resource.expiry.blank?
      Time.at(resource.expiry.to_f / 1000).utc
    end
  end

  def construct_query
    Proc.new do |search|
      query_params = subscription_query_params

      unless query_params[:search].nil?
        # NOTE: Mongoid::Criteria is never nil, even when it matches zero
        # records — it's an empty enumerable. ||= can never reassign here,
        # so each fallback must check .count == 0 explicitly and reassign
        # with = , not ||=, or the chain silently never falls through and
        # the search filter gets dropped entirely (returning every
        # subscription instead of the intended match).
        resources = Member.where(subscription_id: query_params[:search])
        if resources.count == 0
          resources = Rental.where(subscription_id: query_params[:search])
        end
        if resources.count == 0
          resources = Group.where(subscription_id: query_params[:search])
        end
        if resources.count == 0
          resources = Member.search(query_params[:search])
        end
        sub_ids = resources.map(&:subscription_id).reject { |m| m.nil? }
        search.ids.in(sub_ids) unless sub_ids.empty?
      end

      unless query_params[:customer_id].nil?
        member = Member.find_by(customer_id: query_params[:customer_id])
        if member && member.subscription_id
          search.id.is(member.subscription_id)
        end
      end

      if (query_params[:end_date] && query_params[:start_date])
        search.created_at.between(query_params[:start_date], query_params[:end_date])
      elsif query_params[:start_date]
        search.created_at >= query_params[:start_date]
      elsif query_params[:end_date]
        search.created_at <= query_params[:end_date]
      end

      query_array(query_params[:subscription_status], search.status) unless query_params[:subscription_status].nil?
      query_array(query_params[:plan_id], search.plan_id) unless query_params[:plan_id].nil?
    end
  end

  def subscription_query_params
    permitted = params.permit(
      :start_date,
      :startDate,
      :end_date,
      :endDate,
      :search,
      :customer_id,
      :customerId,
      :subscription_status => [],
      :subscriptionStatus => [],
      :plan_id => [],
      :planId => []
    )

    {
      start_date: permitted[:start_date] || permitted[:startDate],
      end_date: permitted[:end_date] || permitted[:endDate],
      search: permitted[:search],
      customer_id: permitted[:customer_id] || permitted[:customerId],
      subscription_status: permitted[:subscription_status] || permitted[:subscriptionStatus],
      plan_id: permitted[:plan_id] || permitted[:planId]
    }.compact
  end
end
