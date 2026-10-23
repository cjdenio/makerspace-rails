module Service
  module CardExpirationCheck
    ZONE = ActiveSupport::TimeZone['America/New_York'].freeze
    CACHE_VERSION = 1
    CACHE_PREFIX = "card_expiration_check:v#{CACHE_VERSION}".freeze

    class << self
      def run!(at: Time.current, gateway: nil)
        local_time = at.in_time_zone(ZONE)
        expiration_search = local_time.strftime('%m/%y')
        gateway ||= ::Service::BraintreeGateway.connect_gateway

        # Braintree returns a paginated collection. Materialize it completely
        # before querying Mongo so the two external data sets are never mixed
        # incrementally.
        customers = gateway.customer.search do |search|
          search.credit_card_expiration_date.is(expiration_search)
        end.to_a

        card_types_by_customer = collect_card_types(customers, local_time)
        members = active_members(card_types_by_customer.keys, at)
        records = members.filter_map do |member|
          card_types = card_types_by_customer[member['customer_id'].to_s]
          next if card_types.blank?

          {
            member_id: member['_id'].to_s,
            customer_id: member['customer_id'].to_s,
            full_name: [member['firstname'], member['lastname']].compact.join(' ').strip,
            slack_id: member['slack_id'].presence,
            card_types: card_types
          }
        end

        cache!(records, local_time)
        records.each { |record| notify!(record) }
        records
      end

      def expiring_member_count(at: Time.current)
        REDIS.get(count_cache_key(at)).to_i
      end

      def card_types_for_member(member_id, at: Time.current)
        REDIS.hget(member_cache_key(at), member_id.to_s).presence
      end

      private

      def collect_card_types(customers, local_time)
        customers.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |customer, result|
          customer.credit_cards.to_a.each do |card|
            next unless expires_during?(card, local_time)
            result[customer.id.to_s] << card.card_type.to_s
          end
        end.transform_values { |types| types.reject(&:blank?).join(', ') }.reject { |_id, types| types.blank? }
      end

      def expires_during?(card, local_time)
        card.expiration_month.to_i == local_time.month &&
          card.expiration_year.to_i % 100 == local_time.year % 100
      end

      def active_members(customer_ids, at)
        return [] if customer_ids.empty?

        Member.collection.aggregate([
          {
            '$match' => {
              'customer_id' => { '$in' => customer_ids },
              '$or' => [
                { 'subscription' => true },
                { 'subscription_id' => { '$ne' => nil } }
              ],
              'status' => { '$in' => Member::ACTIVE_MEMBERSHIP_STATUSES },
              'expirationTime' => { '$gt' => at.to_i * 1000 }
            }
          },
          {
            '$lookup' => {
              'from' => SlackUser.collection.name.to_s,
              'localField' => '_id',
              'foreignField' => 'member_id',
              'as' => 'slack_users'
            }
          },
          {
            '$project' => {
              'customer_id' => 1,
              'firstname' => 1,
              'lastname' => 1,
              'slack_id' => { '$arrayElemAt' => ['$slack_users.slack_id', 0] }
            }
          }
        ]).to_a
      end

      def cache!(records, local_time)
        ttl = seconds_until_next_month(local_time)
        REDIS.set(count_cache_key(local_time), records.length, ex: ttl)
        REDIS.del(member_cache_key(local_time))
        records.each do |record|
          REDIS.hset(member_cache_key(local_time), record[:member_id], record[:card_types])
        end
        REDIS.expire(member_cache_key(local_time), ttl) if records.any?
      end

      def notify!(record)
        notified = notify_member(record)
        profile_url = member_profile_url(record[:member_id])
        member_link = "<#{profile_url}|#{escape_slack(record[:full_name])}>"
        status = notified ? 'yes' : 'no'
        message = "Payment method(s) expiring this month for #{member_link} " \
                  "(Braintree customer #{escape_slack(record[:customer_id])}): " \
                  "#{escape_slack(record[:card_types])}. Member notified via Slack: #{status}."
        ::Service::SlackConnector.send_slack_message(
          message,
          ::Service::SlackConnector.members_relations_channel
        )
      end

      def notify_member(record)
        return false if record[:slack_id].blank?

        payment_methods_url = "#{member_profile_url(record[:member_id])}/settings/payment-methods"
        message = "Your #{escape_slack(record[:card_types].downcase)} payment card(s) expire this month. " \
                  "Please <#{payment_methods_url}|update your payment methods>."
        ::Service::SlackConnector.send_slack_message(message, record[:slack_id])
        true
      rescue => error
        Service::ErrorReporter.notify(error, context: { member_id: record[:member_id], slack_id: record[:slack_id] })
        false
      end

      def member_profile_url(member_id)
        "#{Rails.configuration.x.app_base_url.to_s.sub(%r{/$}, '')}/members/#{member_id}"
      end

      def escape_slack(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end

      def count_cache_key(at)
        "#{CACHE_PREFIX}:#{month_key(at)}:count"
      end

      def member_cache_key(at)
        "#{CACHE_PREFIX}:#{month_key(at)}:members"
      end

      def month_key(at)
        at.in_time_zone(ZONE).strftime('%Y-%m')
      end

      def seconds_until_next_month(local_time)
        [(local_time.end_of_month.end_of_day - local_time).ceil + 1, 1].max
      end
    end
  end
end
