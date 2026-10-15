module Service
  class ShopSlackChannels
    Channel = Data.define(:shop, :id, :name)

    class << self
      def resolved
        configured_shops.filter_map do |shop|
          details = Service::SlackChannelCache.lookup(shop.slack_channel)
          next unless public_channel?(details)

          Channel.new(shop: shop, id: details[:id], name: details[:name])
        rescue => error
          Rails.logger.warn(
            "[ShopSlackChannels] channel resolution failed shop_id=#{shop.id} " \
            "error=#{error.class}: #{error.message}"
          )
          nil
        end
      end

      def associated?(channel_name:, channel_id: nil)
        identifiers = [channel_name, channel_id].filter_map do |value|
          Service::SlackChannelCache.normalize_name(value).presence
        end

        configured_shops.any? do |shop|
          identifiers.include?(Service::SlackChannelCache.normalize_name(shop.slack_channel))
        end
      end

      private

      def configured_shops
        Shop.where(:disabled.ne => true, :slack_channel.nin => [nil, ""]).order_by(name: :asc)
      end

      def public_channel?(details)
        details.present? && details[:id].to_s.match?(/\AC[A-Z0-9]{8,}\z/)
      end
    end
  end
end
