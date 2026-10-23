class CheckoutExpirationNotice
  SETTING = 'checkout_expiration_notice_days'.freeze
  def self.advance_days
    value = SystemConfig.get(SETTING).to_s
    value.match?(/\A\d+\z/) && value.to_i >= 4 ? value.to_i : 14
  end

  def self.run!(at: Time.current)
    failures = []
    cutoff = at.in_time_zone(CheckoutExpiration::ZONE).to_date + advance_days
    ToolCheckout.current_checkouts.where(:expires_on.lte => cutoff, :expires_on.ne => nil).distinct(:member_id).each do |id|
      begin
        with_member_lock(id) { deliver_member!(id, at, failures) }
      rescue => error
        failures << error
        Service::ErrorReporter.notify(error, context: { phase: 'checkout expiration notice', member_id: id.to_s })
      end
    end
    rebuild_expired_rosters!(at, failures)
    raise "Checkout expiration notices failed for #{failures.size} operations; retry to resume" if failures.any?
  end

  def self.rebuild_expired_rosters!(at, failures)
    # Canvas state is independent of member notification eligibility and channels.
    rows = ToolCheckout.expired_at(at).where(:expires_on.ne => nil, 'expiration_notice_state.canvas_completed' => { '$ne' => 3 })
      .includes(:tool).to_a
    rows.group_by { |checkout| checkout.tool&.shop_id }.each_key do |shop_id|
      next unless shop_id
      begin
        job = ToolCheckoutSlackCanvasSyncJob.perform_later(shop_id.to_s)
        raise 'Could not enqueue checkout roster rebuild' unless job
      rescue => error
        failures << error
        Service::ErrorReporter.notify(error, context: { phase: 'checkout expiration roster', shop_id: shop_id.to_s })
      end
    end
  end

  def self.stage(checkout, at)
    today = at.in_time_zone(CheckoutExpiration::ZONE).to_date
    return nil unless checkout.current_checkout? && checkout.expires_on
    return 3 if checkout.expires_on < today
    return 2 if checkout.expires_on - 3 <= today
    return 1 if checkout.expires_on - advance_days <= today
  end

  def self.eligible?(member, checkout, at)
    return false unless member && checkout.tool && !member.direct_notifications_suppressed?
    member.status == 'pending' ? checkout.tool.allow_pending :
      member.status == 'activeMember' && member.expirationTime.to_i > at.to_i * 1000
  end

  def self.deliver_member!(id, at, failures)
    %w[email slack].each do |channel|
      %w[upcoming expired].each do |kind|
        begin
          member = Member.find_by(id: id)
          next unless member
          slack_id = member.slack_user&.slack_id if channel == 'slack'
          next if channel == 'slack' && slack_id.blank?
          next if channel == 'email' && member.email.blank?
          # Reload separately for each channel/message so edits and renewals invalidate pending notices.
          rows = ToolCheckout.current_checkouts.where(member_id: id, :expires_on.ne => nil).includes(:tool).to_a
          due = rows.filter_map do |checkout|
            next unless eligible?(member, checkout, at)
            notice_stage = stage(checkout, at)
            next unless notice_stage && (notice_stage == 3 ? 'expired' : 'upcoming') == kind
            next if checkout.expiration_notice_state.fetch(channel, 0).to_i >= notice_stage
            [checkout, notice_stage]
          end
          next if due.empty?
          payload = due.sort_by { |checkout, _| [checkout.expires_on, checkout.tool.name] }.map do |checkout, _|
            { name: checkout.tool.name, shop: checkout.tool.shop&.name, expires_on: checkout.expires_on.iso8601,
              training_url: checkout.checkout_training_plan_url }
          end
          if channel == 'email'
            CheckoutMailer.expiration_notice(member.id.to_s, payload, kind).deliver_now
          else
            Service::SlackConnector.send_slack_message(slack_message(payload, kind), slack_id)
          end
          due.each do |checkout, notice_stage|
            ToolCheckout.current_checkouts.where(id: checkout.id, expires_on: checkout.expires_on,
              expiration_revision: checkout.expiration_revision)
              .update_all("expiration_notice_state.#{channel}" => notice_stage)
          end
        rescue => error
          failures << error
          Service::ErrorReporter.notify(error, context: { phase: 'checkout expiration delivery', member_id: id.to_s, channel: channel })
        end
      end
    end
  end

  def self.portal_url
    origin = ENV.fetch('APP_DOMAIN').sub(%r{/+\z}, '')
    origin = "https://#{origin}" unless origin.match?(%r{\Ahttps?://})
    "#{origin}/tool-checkouts?mode=self-service"
  end

  def self.slack_message(rows, kind)
    title = kind == 'expired' ? 'Your tool checkouts have expired' : 'Your tool checkouts expire soon'
    lines = rows.map do |row|
      text = "#{CheckoutDisplay.escape(row[:name])} — #{CheckoutDisplay.escape(row[:shop])}: #{row[:expires_on]}"
      url = row[:training_url]
      text += "\n<#{slack_url(url)}|Checkout training plan>" if url.present? && PublicCatalog.safe_url(url)
      text
    end
    "#{title}\n\n#{lines.join("\n\n")}\n\n<#{slack_url(portal_url)}|Request checkout renewal in the Member Portal>"
  end

  def self.slack_url(url)
    url.to_s.gsub('|', '%7C').gsub('>', '%3E').gsub('<', '%3C').gsub('&', '&amp;')
  end

  def self.with_member_lock(id)
    key = "checkout_expiration_notice/#{id}"
    token = SecureRandom.uuid
    acquired = REDIS.set(key, token, nx: true, ex: 600)
    raise 'Checkout expiration notices are already running for this member' unless acquired
    yield
  ensure
    if acquired
      REDIS.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
        keys: [key], argv: [token])
    end
  end
  private_class_method :deliver_member!, :with_member_lock, :rebuild_expired_rosters!
end
