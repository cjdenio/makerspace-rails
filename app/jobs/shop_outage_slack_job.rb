class ShopOutageSlackJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(shop_id, outage_id, channel, name, note)
    ReservationService.send(:with_shop_locks, ["shop-outage-#{shop_id}"]) do
      shop = Shop.find(shop_id)
      return unless shop && shop.outage_id == outage_id

      failures = []
      attempt = lambda do |&block|
        block.call
      rescue StandardError => error
        failures << error
      end
      text = "#{name} was marked out of service by #{shop.outage_actor_name.presence || 'a shop manager'}. " \
        "New reservations for this shop and all its tools are blocked until service is restored.\nReason: #{note}"
      if channel.present? && shop.ts_oos.blank?
        attempt.call do
          destination = Service::SlackConnector.resolved_channel_id(channel)
          response = post(channel: destination, text: text, client_msg_id: outage_id)
          receipt(shop, outage_id, ts_oos: response['ts'], oos_channel_id: response['channel'].presence || destination)
        end
      end

      Array(shop.outage_manager_member_ids).each do |member_id|
        next if shop.outage_dm_receipts[member_id].present?
        attempt.call do
          member = eligible_manager(shop, outage_id, member_id)
          next unless member
          slack_id = member.slack_user&.slack_id.presence
          next unless slack_id
          destination = Service::SlackConnector.client.conversations_open(users: slack_id).dig('channel', 'id')
          raise 'Slack did not return a DM channel' if destination.blank?
          # Recheck after opening the DM as well: membership and shop state may
          # change while Slack is responding. Never trust a queued raw Slack ID.
          member = eligible_manager(shop, outage_id, member_id)
          next unless member && member.slack_user&.slack_id == slack_id
          response = post(channel: destination, text: text, client_msg_id: message_id(outage_id, member_id))
          receipt(shop, outage_id, outage_dm_receipts: shop.outage_dm_receipts.merge(member_id => response['ts']))
        end
      end

      # Clearing before root delivery still produces a threaded recovery message.
      # Tool availability is never mutated.
      shop.reload
      if shop.outage_id == outage_id && !shop.out_of_service? && shop.ts_oos.present? && shop.ts_in_service.blank?
        attempt.call do
          destination = shop.oos_channel_id.presence || Service::SlackConnector.resolved_channel_id(channel)
          response = post(channel: destination, text: "#{name} is back in service. Individual tools marked out of service remain unavailable.",
            thread_ts: shop.ts_oos, reply_broadcast: true, client_msg_id: message_id(outage_id, 'restored'))
          receipt(shop, outage_id, ts_in_service: response['ts'])
        end
      end
      raise failures.first if failures.any?
    end
  end

  private

  def eligible_manager(shop, outage_id, member_id)
    shop.reload
    return unless shop.outage_id == outage_id && shop.out_of_service?
    member = Member.shop_resource_manager_candidates.where(id: member_id, resource_manager_shop_ids: shop.id.to_s).first
    member if member && !member.direct_notifications_suppressed?
  end

  def post(**options)
    response = Service::SlackConnector.client.chat_postMessage(**options,
      mrkdwn: false, parse: 'none', link_names: false, unfurl_links: false, unfurl_media: false)
    raise 'Slack did not return a message timestamp' if response['ts'].blank?
    response
  end

  def receipt(shop, outage_id, **attributes)
    Shop.where(id: shop.id, outage_id: outage_id).update_all(attributes)
    shop.reload
  end

  def message_id(outage_id, destination)
    digest = Digest::SHA256.hexdigest("#{outage_id}/#{destination}")
    [digest[0, 8], digest[8, 4], digest[12, 4], digest[16, 4], digest[20, 12]].join('-')
  end
end
