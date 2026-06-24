class VolunteerController < AuthenticationController

  # GET /api/volunteer/credits
  def credits
    credits = VolunteerCredit.where(member_id: current_member.id)
                             .order_by(created_at: :desc)
    render json: credits, each_serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # GET /api/volunteer/summary
  def summary
    member_id       = current_member.id
    is_earned       = EarnedMembership.where(member_id: member_id).exists?
    year_count      = VolunteerCredit.year_count_for(member_id)
    lifetime_count  = VolunteerCredit.lifetime_count_for(member_id)
    rolling_days    = (SystemConfig.get('volunteer_rolling_days') || 90).to_i
    rolling_count   = VolunteerCredit.rolling_count_for(member_id, rolling_days)
    pending_count   = VolunteerCredit.pending.where(member_id: member_id).count
    discount_active = VolunteerCredit.discount_id.present?

    if discount_active
      discounts_used = VolunteerCredit.discounts_applied_this_year_for(member_id)
      threshold      = VolunteerCredit.credits_per_discount
      max_discounts  = VolunteerCredit.max_discounts_per_year

      message = if is_earned
        nil
      elsif discounts_used >= max_discounts
        "Maximum discounts reached for this year (#{max_discounts}). Resets January 1st."
      else
        credits_until_next = [(threshold * (discounts_used + 1)) - year_count, 0.0].max
        if credits_until_next == 0.0
          'Discount applied to your next billing cycle!'
        else
          "#{credits_until_next} credit#{'s' if credits_until_next != 1.0} until your next discount."
        end
      end
    else
      discounts_used = nil
      threshold      = nil
      max_discounts  = nil
      message        = nil
    end

    render json: {
      year_count:           year_count,
      lifetime_count:       lifetime_count,
      rolling_count:        rolling_count,
      rolling_days:         rolling_days,
      discounts_used:       discounts_used,
      max_discounts:        max_discounts,
      credits_per_discount: threshold,
      pending_count:        pending_count,
      is_earned_member:     is_earned,
      discount_active:      discount_active,
      message:              message
    }
  end

  # GET /api/volunteer/tasks
  # Returns claimable parent tasks (no child documents, no cooling-down recurring tasks).
  def tasks
    tasks = VolunteerTask.claimable
                         .where(parent_task_id: nil)
                         .order_by(task_number: :asc)
    render json: tasks, each_serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # GET /api/volunteer/tasks/my_claims
  # Returns the current member's active child task claims (claimed or pending status)
  # spawned from reusable, repeatable, or recurring parent tasks.
  # Also returns any standard tasks directly claimed by this member.
  # This is the data source for the "My Active Claims" UI section.
  def my_claims
    member_id = current_member.id

    # Child tasks from multi-use parents
    child_claims = VolunteerTask.where(
      claimed_by_id: member_id,
      :parent_task_id.ne => nil,
      :status.in => %w[claimed pending]
    ).order_by(claimed_at: :desc)

    # Standard tasks directly claimed by this member
    standard_claims = VolunteerTask.where(
      claimed_by_id: member_id,
      parent_task_id: nil,
      :status.in => %w[claimed pending]
    ).order_by(claimed_at: :desc)

    all_claims = (child_claims.to_a + standard_claims.to_a)
                   .sort_by { |t| t.claimed_at || Time.at(0) }
                   .reverse

    render json: all_claims, each_serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # GET /api/volunteer/events
  def events
    events = VolunteerEvent.active_events.order_by(created_at: :desc)
    render json: events, each_serializer: VolunteerEventSerializer, adapter: :attributes
  end

  # POST /api/volunteer/tasks/:id/claim
  def claim_task
    unless current_member.status == 'activeMember'
      render json: { error: 'Only active members may claim tasks' }, status: :forbidden and return
    end

    task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if task.nil?

    result = task.claim!(current_member)

    # For multi-use tasks the return value is the child task document;
    # for standard tasks claim! returns self after updating in place.
    render_target = result.is_a?(VolunteerTask) ? result : task
    render json: render_target, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::AlreadyClaimed
    render json: { error: 'You have already claimed this task' }, status: :unprocessable_entity
  rescue Error::CoolingDown
    render json: { error: 'This task is not yet available to claim again' }, status: :unprocessable_entity
  rescue Error::Forbidden
    render json: { error: 'Task is no longer available' }, status: :unprocessable_entity
  end

  # POST /api/volunteer/tasks/:id/complete
  def complete_task
    task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if task.nil?

    task.mark_pending!(current_member)

    ::Service::SlackConnector.send_slack_message(
      "✅ *#{current_member.fullname}* has completed task *#{task.title}* (#{task.display_number}) and is awaiting verification.",
      VolunteerCredit.pending_slack_channel
    )

    render json: task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot mark this task as complete' }, status: :unprocessable_entity
  end

  # POST /api/volunteer/events/:id/checkin
  def checkin_event
    event = VolunteerEvent.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerEvent, { id: params[:id] }) if event.nil?

    unless current_member.status == 'activeMember'
      render json: { error: 'Only active members may check in to events' }, status: :forbidden and return
    end

    if event.status != 'open'
      render json: { error: 'Event is not open for check-in' }, status: :unprocessable_entity and return
    end

    if event.event_date.present? && event.event_date < Date.today
      render json: { error: 'Check-in is no longer available after the event date.' }, status: :unprocessable_entity and return
    end

    if event.attendee_ids.include?(current_member.id)
      render json: { error: 'You are already checked in to this event' }, status: :unprocessable_entity and return
    end

    event.checkin!(current_member)
    render json: event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to check in to this event' }, status: :unprocessable_entity
  end

  # DELETE /api/volunteer/events/:id/checkin
  def remove_checkin
    event = VolunteerEvent.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerEvent, { id: params[:id] }) if event.nil?

    unless event.attendee_ids.include?(current_member.id)
      render json: { error: 'You are not checked in to this event' }, status: :unprocessable_entity and return
    end

    if event.event_date.present? && event.event_date < Date.today
      render json: { error: 'Check-in removal is no longer available after the event date.' }, status: :unprocessable_entity and return
    end

    event.remove_attendee!(current_member, current_member)
    render json: event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to remove check-in. The event may already be closed.' }, status: :unprocessable_entity
  end
end
