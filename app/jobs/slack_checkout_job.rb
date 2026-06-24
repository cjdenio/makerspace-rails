class SlackCheckoutJob < ApplicationJob
  queue_as :default

  def perform(params)
    response_url     = params['response_url']
    channel_name     = params['channel_name']
    text             = params['text'].to_s.strip
    invoker_slack_id = params['user_id']

    parts        = text.split(/\s+/, 2)
    member_token = parts[0]
    tool_name    = parts[1]

    member_slack_id = if slack_mention?(member_token)
      member_token.match(/<@([^|>]+)/i)&.captures&.first
    elsif slack_username?(member_token)
      username = member_token.sub(/\A@/, '')
      SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first&.slack_id
    end

    lock_key = "checkout_lock/#{member_token.downcase}/#{tool_name.downcase}"
    acquired = REDIS.set(lock_key, 1, nx: true, ex: 30)
    unless acquired
      post_response(response_url, :ephemeral, "⚠ A checkout for this member and tool is already being processed. Please wait a moment and try again.")
      return
    end

    begin
      invoker = find_invoker(invoker_slack_id)
      if invoker.nil?
        synced_member = Service::SlackUserSync.sync_single(invoker_slack_id)
        invoker = find_invoker(invoker_slack_id) if synced_member
      end

      unless invoker
        Honeybadger.notify('Slack checkout failed: unauthorized invoker', context: {
          reason:           'Invoker Slack ID not linked to an admin, resource_manager, or checkout approver',
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          member_token:     member_token,
          member_slack_id:  member_slack_id
        })
        post_response(response_url, :ephemeral, 'You are not authorized to check out members on tools.')
        return
      end

      shop = Shop.find_by(slack_channel: channel_name)
      unless shop
        Honeybadger.notify('Slack checkout failed: shop not found for channel', context: {
          reason:           "No Shop record found with slack_channel matching '#{channel_name}'",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          member_token:     member_token,
          member_slack_id:  member_slack_id,
          channel_name:     channel_name
        })
        post_response(response_url, :ephemeral, "No shop is configured for ##{channel_name}. Please use the portal or run /checkout from a shop channel.")
        return
      end

      unless can_approve_for_shop?(invoker, shop)
        Honeybadger.notify('Slack checkout failed: invoker not approved for shop', context: {
          reason:           "Invoker does not have checkout approval rights for shop '#{shop.name}' (id: #{shop.id})",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          member_token:     member_token,
          member_slack_id:  member_slack_id,
          shop_name:        shop.name,
          shop_id:          shop.id.to_s
        })
        post_response(response_url, :ephemeral, "You are not authorized to approve checkouts for #{shop.name}.")
        return
      end

      tool = Tool.where(shop_id: shop.id).find_by(name: /#{Regexp.escape(tool_name)}/i)
      unless tool
        tool_list = Tool.where(shop_id: shop.id).pluck(:name).join(', ')
        Honeybadger.notify('Slack checkout failed: tool not found', context: {
          reason:             "No tool matching '#{tool_name}' found in shop '#{shop.name}'",
          command_text:       text,
          invoker_slack_id:   invoker_slack_id,
          member_token:       member_token,
          member_slack_id:    member_slack_id,
          tool_name_searched: tool_name,
          shop_name:          shop.name,
          available_tools:    tool_list
        })
        post_response(response_url, :ephemeral, "Tool '#{tool_name}' not found in #{shop.name}. Available: #{tool_list}")
        return
      end

      member = find_member_from_token(member_token)
      if member.nil? && (slack_mention?(member_token) || slack_username?(member_token))
        synced_slack_id = member_slack_id
        if synced_slack_id
          Service::SlackUserSync.sync_single(synced_slack_id)
          member = find_member_from_token(member_token)
        end
      end

      unless member
        if slack_mention?(member_token)
          Honeybadger.notify('Slack checkout failed: member not found by Slack ID', context: {
            reason:           'Slack mention parsed but no SlackUser/Member record linked to this Slack ID',
            command_text:     text,
            invoker_slack_id: invoker_slack_id,
            member_token:     member_token,
            member_slack_id:  member_slack_id
          })
          post_response(response_url, :ephemeral, "No member found linked to that Slack account. Please resubmit with their email address instead:\n`/checkout member@email.com #{tool_name}`")
        elsif slack_username?(member_token)
          Honeybadger.notify('Slack checkout failed: member not found by Slack username', context: {
            reason:           'Plain @username not matched to any SlackUser name record',
            command_text:     text,
            invoker_slack_id: invoker_slack_id,
            member_token:     member_token,
            member_slack_id:  member_slack_id
          })
          post_response(response_url, :ephemeral, "No member found with Slack username #{member_token}. Try using their email instead:\n`/checkout member@email.com #{tool_name}`")
        else
          Honeybadger.notify('Slack checkout failed: member not found by email', context: {
            reason:           'No Member record found with email matching member token',
            command_text:     text,
            invoker_slack_id: invoker_slack_id,
            member_token:     member_token,
            member_slack_id:  nil
          })
          post_response(response_url, :ephemeral, "No member found with email #{member_token}.")
        end
        return
      end

      # Fix #1 — Mongoid 7 exists? requires scoped query, not arguments
      if ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
        post_response(response_url, :ephemeral, "#{member.fullname} is already checked out on #{tool.name}.")
        return
      end

      checkout = ToolCheckout.new(
        member_id:      member.id,
        tool_id:        tool.id,
        approved_by_id: invoker.id,
        signed_off_via: 'slack',
        checked_out_at: Time.now
      )

      begin
        checkout.save!
      rescue => err
        Honeybadger.notify('Slack checkout failed: could not save ToolCheckout', context: {
          reason:           "checkout.save! raised: #{err.message}",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          member_token:     member_token,
          member_slack_id:  member_slack_id,
          member_id:        member.id.to_s,
          tool_id:          tool.id.to_s,
          tool_name:        tool.name
        })
        post_response(response_url, :ephemeral, 'Failed to create checkout record. Please try again or use the portal.')
        return
      end

      begin
        checkout.send_checkout_slack_notification
      rescue => err
        Honeybadger.notify('Slack checkout saved but notification failed', context: {
          reason:           "send_checkout_slack_notification raised: #{err.message}",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          member_token:     member_token,
          member_slack_id:  member_slack_id,
          member_id:        member.id.to_s,
          tool_id:          tool.id.to_s,
          tool_name:        tool.name,
          checkout_id:      checkout.id.to_s
        })
      end

      unmet   = unmet_prerequisites(member, tool)
      warning = unmet.any? ? "\n⚠ Warning: #{member.firstname} has not been checked out on prerequisite(s): #{unmet.map(&:name).join(', ')}" : ''

      post_response(response_url, :in_channel, "✅ #{member.fullname} has been checked out on *#{tool.name}* in *#{shop.name}* by #{invoker.fullname}.#{warning}")

    ensure
      REDIS.del(lock_key)
    end
  end

  private

  def post_response(response_url, response_type, text)
    uri  = URI.parse(response_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req  = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = { response_type: response_type, text: text }.to_json
    http.request(req)
  rescue => err
    Honeybadger.notify('Slack checkout: failed to post response to response_url', context: {
      error:        err.message,
      response_url: response_url,
      text:         text
    })
  end

  def slack_mention?(token)
    token.start_with?('<@')
  end

  def slack_username?(token)
    token.start_with?('@') && !token.start_with?('<@')
  end

  def find_member_from_token(token)
    if slack_mention?(token)
      slack_id = token.match(/<@([^|>]+)/i)&.captures&.first
      return nil unless slack_id
      slack_user = SlackUser.find_by(slack_id: slack_id)
      slack_user ? Member.find(slack_user.member_id) : nil
    elsif slack_username?(token)
      username   = token.sub(/\A@/, '')
      slack_user = SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first
      slack_user ? Member.find(slack_user.member_id) : nil
    else
      Member.find_by(email: token.downcase)
    end
  end

  def find_invoker(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    member = Member.find(slack_user.member_id)
    return member if member.role.in?(%w[admin resource_manager])
    return member if CheckoutApprover.is_approver?(member.id)
    nil
  end

  def can_approve_for_shop?(member, shop)
    return true if member.role.in?(%w[admin resource_manager])
    approver = CheckoutApprover.find_by(member_id: member.id)
    approver && approver.can_approve_for_shop?(shop.id)
  end

  def unmet_prerequisites(member, tool)
    return [] if tool.prerequisite_ids.blank?
    checked_out_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    tool.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_ids.include?(pid) }.map do |pid|
      Tool.find(pid) rescue nil
    end.compact
  end
end
