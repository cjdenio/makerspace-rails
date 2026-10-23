class ToolAvailabilityService
  ToolScope = Struct.new(:shop_id, :tool)
  def self.set!(tool:, actor:, value:)
    proxy = ToolScope.new(tool.shop_id, tool)
    raise Error::Forbidden.new unless FixTicketPolicy.new(actor, proxy).staff?
    raise Error::UnprocessableEntity.new('out_of_service must be a boolean') unless [true, false].include?(value)
    changed = false
    ReservationService.send(:with_shop_locks, [tool.shop_id]) do
      previous = !!tool.reload.out_of_service
      if previous != value
        tool.update!(out_of_service: value)
        changed = true
        Service::AuditLogger.log(log_type: 'portal', event_type: 'tool_availability_changed',
          resource_type: 'Tool', resource_id: tool.id, actor: actor,
          field_changes: { 'out_of_service' => [previous, value] })
      end
    end
    affected = Reservation.where(tool_ids: tool.id.to_s, :status.in => Reservation::ACTIVE_STATUSES, :end_at.gt => Time.current)
    affected.flat_map { |reservation| ReservationService.send(:slack_canvas_targets, reservation) }
      .uniq.group_by(&:first).each do |shop_id, targets|
        ReservationSlackCanvasSyncJob.perform_later(shop_id, targets.map { |(_, date)| date.iso8601 })
      end
    # Existing reservation holders need to hear it directly -- the canvas
    # refresh above only updates a shared board, and only staff otherwise see
    # this affected list (in the response below, for their own review).
    if changed && value && affected.exists?
      ToolOutageNotificationJob.perform_later(tool.id.to_s, affected.pluck(:id).map(&:to_s))
    end
    { outOfService: value, affectedReservations: affected.order_by(start_at: :asc).limit(100).map { |r| { id: r.id.to_s, startAt: r.start_at, endAt: r.end_at } },
      affectedCount: affected.count }
  end

  class << self
    def enqueue_reservation_canvas_refreshes(tool)
      return if tool.shop_id.blank?

      today = Time.current.in_time_zone(ReservationService::ZONE).to_date
      dates = [today, today + 1.day]
      window_start = beginning_of_day(dates.first)
      window_end = beginning_of_day(dates.last + 1.day)
      reservations = Reservation.blocking.where(
        shop_id: tool.shop_id,
        :tool_ids.in => [tool.id.to_s],
        :start_at.lt => window_end,
        :end_at.gt => window_start
      ).to_a

      affected_dates = dates.select do |date|
        day_start = beginning_of_day(date)
        day_end = beginning_of_day(date + 1.day)
        reservations.any? do |reservation|
          reservation.start_at < day_end && reservation.end_at > day_start
        end
      end
      return if affected_dates.empty?

      ReservationSlackCanvasSyncJob.perform_later(
        tool.shop_id.to_s,
        affected_dates.map(&:iso8601)
      )
    end

    private

    def beginning_of_day(date)
      ReservationService::ZONE.local(date.year, date.month, date.day).utc
    end
  end
end
