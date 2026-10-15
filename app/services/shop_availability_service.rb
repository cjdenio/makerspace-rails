class ShopAvailabilityService
  def self.set!(shop:, actor:, value:, note: nil)
    unless actor && (actor.role.in?(%w[admin board_member]) || actor.manages_shop?(shop))
      raise Error::Forbidden.new
    end
    raise Error::UnprocessableEntity.new('out_of_service must be a boolean') unless [true, false].include?(value)
    note = note.to_s.strip
    raise Error::UnprocessableEntity.new('Enter a note explaining why the shop is out of service') if value && note.blank?

    ReservationService.send(:with_shop_locks, [shop.id]) do
      previous = !!shop.reload.out_of_service
      previous_note = shop.out_of_service_note
      if previous != value
        changes = { out_of_service: value }
        if value
          managers = Member.shop_resource_manager_candidates.where(resource_manager_shop_ids: shop.id.to_s)
          changes.merge!(out_of_service_note: note, ts_oos: nil, outage_id: SecureRandom.uuid,
            outage_actor_name: actor.fullname, outage_manager_slack_ids: [],
            outage_manager_member_ids: managers.reject(&:direct_notifications_suppressed?).map { |manager| manager.id.to_s },
            outage_dm_receipts: {}, oos_channel_id: nil, ts_in_service: nil)
        end
        shop.update!(changes)
        Service::AuditLogger.log(log_type: 'portal', event_type: 'shop_availability_changed',
          resource_type: 'Shop', resource_id: shop.id, actor: actor,
          field_changes: { 'out_of_service' => [previous, value], 'out_of_service_note' => [previous_note, shop.out_of_service_note] })
      end
      # Repeated requests can recover a failed enqueue without starting a new outage.
      if shop.outage_id.present? && (shop.slack_channel.present? || shop.ts_oos.present? || shop.outage_manager_member_ids.present?)
        ShopOutageSlackJob.perform_later(shop.id.to_s, shop.outage_id, shop.slack_channel, shop.name, shop.out_of_service_note)
      end
      if shop.slack_channel.present?
        today = Time.current.in_time_zone(ReservationService::ZONE).to_date
        ReservationSlackCanvasSyncJob.perform_later(shop.id.to_s, [today.iso8601, (today + 1.day).iso8601])
      end
    end
    { outOfService: !!shop.out_of_service, outOfServiceNote: shop.out_of_service_note }
  end
end
