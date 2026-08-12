class ReservationService
  ZONE = ActiveSupport::TimeZone["America/New_York"].freeze
  LOCK_TTL_SECONDS = 15

  class << self
    def preview(member:, attributes:, reservation: nil)
      normalized = normalize(attributes, reservation)
      if reservation && !material_edit?(reservation, normalized)
        errors = normalized[:title].blank? ? ["Title is required"] : []
        reasons = Array(reservation.approval_reasons)
        return {
          eligible: errors.empty?,
          errors: errors,
          conflicts: [],
          missingPrerequisites: [],
          requiresApproval: reservation.status == "pending",
          approvalReasons: reasons,
          approvalDetails: reservation.effective_approval_details,
          maximumDurationHours: ((reservation.end_at - reservation.start_at) / 1.hour).to_f
        }
      end

      evaluation = evaluate(member: member, attributes: normalized, reservation: reservation)
      {
        eligible: evaluation[:errors].empty? && evaluation[:conflicts].empty?,
        errors: evaluation[:errors],
        conflicts: evaluation[:conflicts],
        missingPrerequisites: evaluation[:missing_prerequisites],
        requiresApproval: evaluation[:approval_reasons].present?,
        approvalReasons: evaluation[:approval_reasons],
        approvalDetails: evaluation[:approval_details],
        maximumDurationHours: evaluation[:maximum_duration_hours]
      }
    end

    def create!(member:, attributes:, source: "portal")
      normalized = normalize(attributes)
      with_shop_lock(normalized[:shop_id]) do
        evaluation = evaluate(member: member, attributes: normalized)
        raise_for_evaluation!(
          evaluation,
          member: member,
          attributes: normalized,
          operation: "create"
        )

        reservation = Reservation.create!(
          normalized.merge(
            member_id: member.id,
            status: evaluation[:approval_reasons].present? ? "pending" : "approved",
            approval_reasons: evaluation[:approval_reasons],
            approval_details: evaluation[:approval_details],
            source: source,
            calendar_sync_status: "pending"
          )
        )
        enqueue_external_syncs(reservation)
        reservation
      end
    end

    def update!(reservation:, attributes:)
      unless reservation.blocking? && reservation.end_at > Time.current
        raise ::Error::UnprocessableEntity.new("Only future active reservations can be changed")
      end

      normalized = normalize(attributes, reservation)
      previous_canvas_targets = slack_canvas_targets(reservation)
      with_shop_locks([reservation.shop_id, normalized[:shop_id]]) do
        unless material_edit?(reservation, normalized)
          reservation.update!(
            title: normalized[:title],
            calendar_sync_status: "pending",
            calendar_sync_error: nil
          )
          enqueue_external_syncs(
            reservation,
            previous_canvas_targets: previous_canvas_targets
          )
          next reservation
        end

        evaluation = evaluate(member: reservation.member, attributes: normalized, reservation: reservation)
        raise_for_evaluation!(
          evaluation,
          member: reservation.member,
          attributes: normalized,
          operation: "update",
          reservation: reservation
        )

        reservation.update!(
          normalized.merge(
            status: evaluation[:approval_reasons].present? ? "pending" : "approved",
            approval_reasons: evaluation[:approval_reasons],
            approval_details: evaluation[:approval_details],
            decided_by_id: nil,
            decided_at: nil,
            decision_note: nil,
            calendar_sync_status: "pending",
            calendar_sync_error: nil
          )
        )
        enqueue_external_syncs(
          reservation,
          previous_canvas_targets: previous_canvas_targets
        )
        reservation
      end
    end

    def cancel!(reservation:, actor:, reason: nil)
      unless reservation.blocking? && reservation.end_at > Time.current
        raise ::Error::UnprocessableEntity.new("Only current or future active reservations can be cancelled")
      end

      with_shop_lock(reservation.shop_id) do
        reservation.update!(
          status: "cancelled",
          decision_note: reason,
          decided_by_id: actor&.id,
          decided_at: Time.current,
          calendar_sync_status: "pending",
          calendar_sync_error: nil
        )
        enqueue_external_syncs(reservation)
        reservation
      end
    end

    def approve!(reservation:, actor:, note: nil)
      raise ::Error::UnprocessableEntity.new("Only pending reservations can be approved") unless reservation.status == "pending"
      raise ::Error::Forbidden.new("You cannot approve your own reservation") if reservation.member_id.to_s == actor.id.to_s

      reservation.update!(
        status: "approved",
        decision_note: note,
        decided_by_id: actor.id,
        decided_at: Time.current,
        calendar_sync_status: "pending",
        calendar_sync_error: nil
      )
      enqueue_external_syncs(reservation)
      reservation
    end

    def deny!(reservation:, actor:, note: nil)
      raise ::Error::UnprocessableEntity.new("Only pending reservations can be denied") unless reservation.status == "pending"

      reservation.update!(
        status: "denied",
        decision_note: note,
        decided_by_id: actor.id,
        decided_at: Time.current,
        calendar_sync_status: "pending",
        calendar_sync_error: nil
      )
      enqueue_external_syncs(reservation)
      reservation
    end

    private

    def normalize(attributes, reservation = nil)
      source = attributes.to_h.symbolize_keys
      {
        title: source[:title].presence || reservation&.title,
        shop_id: source[:shop_id].presence || reservation&.shop_id,
        reservation_scope: source[:reservation_scope].presence || reservation&.reservation_scope,
        tool_ids: source.key?(:tool_ids) ? Array(source[:tool_ids]).map(&:to_s).uniq : Array(reservation&.tool_ids).map(&:to_s),
        start_at: parse_time(source[:start_at].presence || reservation&.start_at),
        end_at: parse_time(source[:end_at].presence || reservation&.end_at)
      }
    end

    def parse_time(value)
      return value.utc if value.respond_to?(:utc)
      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def evaluate(member:, attributes:, reservation: nil)
      member.reload if member.persisted?
      errors = []
      conflicts = []
      missing = []
      approval_reasons = []
      approval_details = []
      blackout_window_valid = false
      duration_session_existing = nil
      board_override = board_reservation_override?(member)

      shop = Shop.where(id: attributes[:shop_id]).first
      unless shop
        return {
          errors: ["Selected shop was not found"],
          conflicts: [],
          missing_prerequisites: [],
          approval_reasons: [],
          approval_details: [],
          maximum_duration_hours: 0
        }
      end
      tools = attributes[:reservation_scope] == "tools" ?
        Tool.where(shop_id: shop.id, :id.in => attributes[:tool_ids]).to_a : []
      resources = attributes[:reservation_scope] == "shop" ? [shop] : tools

      errors << "Title is required" if attributes[:title].blank?
      unless board_override || member.status == 'pending' || member.active_unexpired?
        errors << "Your membership is inactive or expired. An active membership is required to make a reservation"
      end
      if !board_override && member.status == 'pending'
        if attributes[:reservation_scope] != 'tools' || tools.any? { |tool| !tool.allow_pending }
          errors << "Pending members may only reserve tools that allow pending-member access"
        end
      end
      errors << "Start and end times are required" if attributes[:start_at].blank? || attributes[:end_at].blank?
      errors << "Start time must be in the future" if attributes[:start_at].present? && attributes[:start_at] < Time.current
      errors << "End time must be after start time" if attributes[:start_at].present? && attributes[:end_at].present? && attributes[:end_at] <= attributes[:start_at]
      errors << "Times must use 30-minute increments" unless half_hour?(attributes[:start_at]) && half_hour?(attributes[:end_at])
      errors << "Reservation scope must be shop or tools" unless Reservation::SCOPES.include?(attributes[:reservation_scope])
      errors << "Select at least one tool" if attributes[:reservation_scope] == "tools" && attributes[:tool_ids].empty?
      errors << "One or more selected tools are invalid" if attributes[:reservation_scope] == "tools" && tools.length != attributes[:tool_ids].length
      errors << "The selected shop is not reservable" if attributes[:reservation_scope] == "shop" && (!shop.reservable || shop.disabled?)
      if attributes[:reservation_scope] == "tools" &&
          (shop.disabled? || tools.any? { |tool| !tool.reservable || tool.disabled? })
        errors << "One or more selected tools are not reservable"
      end

      if attributes[:end_at].present? && !board_override && member.status != 'pending' && !member.active_membership_subscription?
        membership_expiration = member.membership_expires_at
        if membership_expiration.present? && attributes[:end_at] > membership_expiration
          expiration_text = membership_expiration.in_time_zone(ZONE).strftime("%B %-d, %Y at %H:%M")
          errors << "This reservation ends after your membership expires on #{expiration_text}. " \
            "Without an active recurring membership, reservations must end before your current membership expires"
        end
      end

      if attributes[:start_at].present? && attributes[:end_at].present? && resources.present?
        start_date = attributes[:start_at].in_time_zone(ZONE).to_date
        today = Time.current.in_time_zone(ZONE).to_date
        strict_horizon = resources.map(&:reservation_horizon_days).min
        unless board_override
          errors << "Reservation is outside the allowed booking window" if start_date > today + strict_horizon
        end

        duration_hours = (attributes[:end_at] - attributes[:start_at]) / 1.hour
        strict_duration = board_override ? 72.0 : resources.map(&:max_reservation_duration_hours).min.to_f
        errors << "Reservation exceeds the maximum duration" if duration_hours > strict_duration
        blackout_window_valid = duration_hours.positive? &&
          duration_hours <= strict_duration
        unless duration_session_exempt?(member)
          duration_session_existing = duration_session_existing_by_resource(
            member: member,
            shop: shop,
            resources: resources,
            reservation_scope: attributes[:reservation_scope],
            reservation: reservation
          )
          errors.concat(duration_session_errors(
            member: member,
            shop: shop,
            tools: tools,
            reservation_scope: attributes[:reservation_scope],
            start_at: attributes[:start_at],
            end_at: attributes[:end_at],
            reservation: reservation,
            existing_by_resource: duration_session_existing
          ))
        end
      end

      prerequisite_ids = if attributes[:reservation_scope] == "shop"
        Array(shop.reservation_prerequisite_tool_ids).map(&:to_s)
      else
        tools.flat_map(&:effective_reservation_prerequisite_ids).uniq
      end
      if member.status == 'pending'
        prerequisite_ids -= tools.select(&:allow_pending).map { |tool| tool.id.to_s }
      end
      unless board_override
        checked_out_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
        missing_ids = prerequisite_ids - checked_out_ids
        missing = Tool.where(:id.in => missing_ids).map { |tool| { id: tool.id.to_s, name: tool.name } }
        if missing_ids.present?
          missing_names = missing.map { |tool| tool[:name] }.presence || missing_ids
          errors << "Missing required checkout(s): #{missing_names.join(', ')}"
        end
      end

      if attributes[:start_at].present? && attributes[:end_at].present?
        overlapping = overlapping_reservations(attributes[:start_at], attributes[:end_at], reservation)
        unless board_override
          shop_overlaps = overlapping.where(shop_id: shop.id)
          conflicts.concat(capacity_conflicts(
            shop: shop,
            tools: tools,
            reservation_scope: attributes[:reservation_scope],
            overlaps: shop_overlaps.to_a,
            start_at: attributes[:start_at],
            end_at: attributes[:end_at]
          ))

          member_overlap = overlapping.where(member_id: member.id).exists?
          if member_overlap
            approval_reasons << "overlapping_member_reservation"
            approval_details << approval_detail(
              "overlapping_member_reservation",
              "This reservation overlaps another reservation you hold."
            )
          end
        end
      end

      if !board_override && resources.any?(&:reservation_requires_approval)
        approval_reasons << "resource_requires_approval"
        approval_details << approval_detail(
          "resource_requires_approval",
          "The selected resource requires manager approval."
        )
      end
      if !board_override && blackout_window_valid
        blackout_occurrences = ReservationBlackout.occurrences_overlapping(
          shop_id: shop.id,
          start_at: attributes[:start_at],
          end_at: attributes[:end_at]
        )
        blackout_occurrences
          .uniq { |occurrence| occurrence[:blackout].id.to_s }
          .each do |occurrence|
            blackout = occurrence[:blackout]
            approval_reasons << "blackout"
            approval_details << approval_detail(
              "blackout",
              "This reservation overlaps the shop blackout “#{blackout.title}”.",
              blackoutId: blackout.id.to_s,
              blackoutTitle: blackout.title
            )
          end
      end
      maximum_duration = maximum_duration_hours(
        member: member,
        shop: shop,
        tools: tools,
        reservation_scope: attributes[:reservation_scope],
        start_at: attributes[:start_at],
        resources: resources,
        reservation: reservation,
        duration_session_existing: duration_session_existing
      )

      {
        errors: errors.uniq,
        conflicts: conflicts.uniq,
        missing_prerequisites: missing,
        approval_reasons: approval_reasons.uniq,
        approval_details: approval_details.uniq,
        maximum_duration_hours: maximum_duration
      }
    rescue Mongoid::Errors::DocumentNotFound, Mongoid::Errors::InvalidFind
      {
        errors: ["Selected shop was not found"],
        conflicts: [],
        missing_prerequisites: [],
        approval_reasons: [],
        approval_details: [],
        maximum_duration_hours: 0
      }
    end

    def overlapping_reservations(start_at, end_at, reservation)
      criteria = Reservation.blocking.where(:start_at.lt => end_at, :end_at.gt => start_at)
      criteria = criteria.where(:id.ne => reservation.id) if reservation
      criteria
    end

    def half_hour?(time)
      time.present? && (time.min == 0 || time.min == 30) && time.sec == 0
    end

    def maximum_duration_hours(
      member:,
      shop:,
      tools:,
      reservation_scope:,
      start_at:,
      resources:,
      reservation:,
      duration_session_existing:
    )
      return 0 unless start_at.present? && resources.present?

      return 72.0 if board_reservation_override?(member)

      configured_max = resources.map(&:max_reservation_duration_hours).min.to_f
      if !member.active_membership_subscription? && member.membership_expires_at.present?
        membership_max = (member.membership_expires_at - start_at) / 1.hour
        configured_max = [configured_max, membership_max].min
      end

      steps = [(configured_max * 2).floor, 0].max
      return 0 if steps.zero?

      window_end = start_at + (steps * 0.5).hours
      overlaps = overlapping_reservations(start_at, window_end, reservation)
        .where(shop_id: shop.id).to_a
      allowed = 0.0

      1.upto(steps) do |step|
        candidate_end = start_at + (step * 0.5).hours
        unless duration_session_exempt?(member)
          break if duration_session_errors(
            member: member,
            shop: shop,
            tools: tools,
            reservation_scope: reservation_scope,
            start_at: start_at,
            end_at: candidate_end,
            reservation: reservation,
            existing_by_resource: duration_session_existing
          ).present?
        end
        candidate_overlaps = overlaps.select do |existing|
          existing.start_at < candidate_end && existing.end_at > start_at
        end
        break if capacity_conflicts(
          shop: shop,
          tools: tools,
          reservation_scope: reservation_scope,
          overlaps: candidate_overlaps,
          start_at: start_at,
          end_at: candidate_end
        ).present?

        allowed = step * 0.5
      end
      allowed
    end

    def board_reservation_override?(member)
      member.role == "board_member"
    end

    def duration_session_exempt?(member)
      member.role.in?(%w[admin board_member])
    end

    def duration_session_errors(
      member:,
      shop:,
      tools:,
      reservation_scope:,
      start_at:,
      end_at:,
      reservation:,
      existing_by_resource: nil
    )
      resources = reservation_scope == "shop" ? [shop] : tools
      resources.filter_map do |resource|
        existing = existing_by_resource&.fetch(resource.id.to_s, nil) ||
          member_resource_reservations(
            member: member,
            shop: shop,
            resource: resource,
            reservation_scope: reservation_scope,
            reservation: reservation
          )
        maximum = resource.max_reservation_duration_hours.to_f
        gap_hours = ((maximum / 3.0) * 2).ceil / 2.0
        entries = existing.map do |item|
          {
            start_at: item.start_at,
            end_at: item.end_at,
            duration: (item.end_at - item.start_at) / 1.hour,
            candidate: false
          }
        end
        entries << {
          start_at: start_at,
          end_at: end_at,
          duration: (end_at - start_at) / 1.hour,
          candidate: true
        }
        candidate_cluster = reservation_session_clusters(entries, gap_hours)
          .find { |cluster| cluster.any? { |entry| entry[:candidate] } }
        total = candidate_cluster.to_a.sum { |entry| entry[:duration] }
        next if total <= maximum + 0.0001

        label = reservation_scope == "shop" ? shop.name : resource.name
        "#{label} reservations separated by less than #{format_hours(gap_hours)} " \
          "may total at most #{format_hours(maximum)}"
      end
    end

    def duration_session_existing_by_resource(
      member:,
      shop:,
      resources:,
      reservation_scope:,
      reservation:
    )
      resources.index_with do |resource|
        member_resource_reservations(
          member: member,
          shop: shop,
          resource: resource,
          reservation_scope: reservation_scope,
          reservation: reservation
        )
      end.transform_keys { |resource| resource.id.to_s }
    end

    def member_resource_reservations(member:, shop:, resource:, reservation_scope:, reservation:)
      criteria = Reservation.blocking.where(
        member_id: member.id,
        shop_id: shop.id,
        reservation_scope: reservation_scope
      )
      criteria = criteria.where(tool_ids: resource.id.to_s) if reservation_scope == "tools"
      criteria = criteria.where(:id.ne => reservation.id) if reservation
      criteria.to_a
    end

    def reservation_session_clusters(entries, gap_hours)
      clusters = []
      entries.sort_by { |entry| [entry[:start_at], entry[:end_at]] }.each do |entry|
        cluster = clusters.last
        cluster_end = cluster&.map { |item| item[:end_at] }&.max
        if cluster.nil? || entry[:start_at] - cluster_end >= gap_hours.hours
          clusters << [entry]
        else
          cluster << entry
        end
      end
      clusters
    end

    def format_hours(value)
      number = value.to_f
      label = number == number.to_i ? number.to_i : number
      "#{label} hour#{number == 1.0 ? '' : 's'}"
    end

    def approval_detail(code, message, extra = {})
      { code: code, message: message }.merge(extra)
    end

    def capacity_conflicts(shop:, tools:, reservation_scope:, overlaps:, start_at:, end_at:)
      if reservation_scope == "shop"
        conflicts = []
        conflicts << "A tool in this shop is already reserved" if overlaps.any? { |item| item.reservation_scope == "tools" }
        shop_reservations = overlaps.select { |item| item.reservation_scope == "shop" }
        if capacity_reached?(shop_reservations, shop.max_concurrent_reservations, start_at, end_at)
          conflicts << "The shop has reached its reservation capacity"
        end
        conflicts
      elsif reservation_scope == "tools"
        conflicts = []
        conflicts << "The entire shop is already reserved" if overlaps.any? { |item| item.reservation_scope == "shop" }
        tools.each do |tool|
          tool_reservations = overlaps.select do |item|
            item.reservation_scope == "tools" && Array(item.tool_ids).map(&:to_s).include?(tool.id.to_s)
          end
          if capacity_reached?(tool_reservations, tool.max_concurrent_reservations, start_at, end_at)
            conflicts << "#{tool.name} has reached its reservation capacity"
          end
        end
        conflicts
      else
        []
      end
    end

    def capacity_reached?(reservations, limit, start_at, end_at)
      return false if reservations.empty?

      boundaries = ([start_at, end_at] + reservations.flat_map { |item| [item.start_at, item.end_at] })
        .select { |time| time >= start_at && time <= end_at }
        .uniq.sort
      boundaries.each_cons(2).any? do |segment_start, segment_end|
        next false if segment_end <= segment_start
        reservations.count do |item|
          item.start_at < segment_end && item.end_at > segment_start
        end >= limit
      end
    end

    def material_edit?(reservation, attributes)
      reservation.shop_id.to_s != attributes[:shop_id].to_s ||
        reservation.reservation_scope != attributes[:reservation_scope] ||
        Array(reservation.tool_ids).map(&:to_s).sort != Array(attributes[:tool_ids]).map(&:to_s).sort ||
        reservation.start_at != attributes[:start_at] ||
        reservation.end_at != attributes[:end_at]
    end

    def raise_for_evaluation!(evaluation, member:, attributes:, operation:, reservation: nil)
      reasons = (evaluation[:errors] + evaluation[:conflicts]).uniq
      if reasons.present?
        Rails.logger.warn(
          "[ReservationRejected] operation=#{operation} member_id=#{member.id} " \
          "reservation_id=#{reservation&.id || 'new'} shop_id=#{attributes[:shop_id]} " \
          "reason=#{reasons.join(' | ')}"
        )
      end
      raise ::Error::UnprocessableEntity.new(evaluation[:errors].join(". ")) if evaluation[:errors].present?
      raise ::Error::Conflict.new(evaluation[:conflicts].join(". ")) if evaluation[:conflicts].present?
    end

    def with_shop_lock(shop_id)
      token = SecureRandom.uuid
      key = "reservation_lock/shop/#{shop_id}"
      acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
      raise ::Error::Conflict.new("Reservation processing is busy; please retry") unless acquired

      yield
    rescue Redis::BaseError => error
      Rails.logger.error(
        "[ReservationLockError] shop_id=#{shop_id} error=#{error.class}: #{error.message}"
      )
      raise ::Error::Conflict.new(
        "Reservation processing is temporarily unavailable. Please retry in a moment"
      )
    ensure
      if key && token
        begin
          REDIS.eval(
            "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
            keys: [key],
            argv: [token]
          )
        rescue Redis::BaseError
          nil
        end
      end
    end

    def with_shop_locks(shop_ids, &block)
      ids = Array(shop_ids).compact.map(&:to_s).uniq.sort
      acquire = lambda do |index|
        return block.call if index >= ids.length

        with_shop_lock(ids[index]) { acquire.call(index + 1) }
      end
      acquire.call(0)
    end

    def enqueue_external_syncs(reservation, previous_canvas_targets: [])
      ReservationCalendarSyncJob.perform_later(reservation.id.to_s)
      ReservationSlackReminderSyncJob.perform_later(reservation.id.to_s)

      targets = (Array(previous_canvas_targets) + slack_canvas_targets(reservation))
        .uniq
        .group_by(&:first)
      targets.each do |shop_id, shop_targets|
        dates = shop_targets.map { |(_, date)| date.iso8601 }.uniq
        ReservationSlackCanvasSyncJob.perform_later(shop_id, dates)
      end
    end

    def slack_canvas_targets(reservation)
      return [] if reservation.shop_id.blank? ||
        reservation.start_at.blank? ||
        reservation.end_at.blank?

      today = Time.current.in_time_zone(ZONE).to_date
      relevant_dates = [today, today + 1.day]
      start_date = reservation.start_at.in_time_zone(ZONE).to_date
      end_date = reservation.end_at.in_time_zone(ZONE).to_date

      relevant_dates
        .select { |date| date >= start_date && date <= end_date }
        .map { |date| [reservation.shop_id.to_s, date] }
    end
  end
end
