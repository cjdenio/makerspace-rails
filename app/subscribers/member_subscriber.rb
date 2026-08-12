module MemberSubscriber
  extend Service::GoogleDrive
  extend Service::SlackConnector
  extend Service::BraintreeGateway
  extend self

  def subscribe
    Member.subscribe(:create) do |event|
      send_slack_invite(event[:model])
    end


    Member.subscribe(:billing_info_changed) do |event|
      update_braintree_customer_info(event[:model])
    end

    Member.subscribe(:destroy) do |event|
      subscription_id = event[:model].subscription_id
      if subscription_id
        begin 
          ::BraintreeService::Subscription.cancel(connect_gateway(), subscription_id)
        rescue => err
          ::Service::SlackConnector.send_slack_message("Error cancelling #{event[:model].fullname}'s membership_subscription. Err: #{err}")
        end
      end

      rentals = event[:model].rentals
      if rentals.length
        rentals.map { |rental| rental.destroy }
      end
    end
  end

  private

  def send_slack_invite(member)
    ::Service::MemberProvisioning.invite_slack(member)
  rescue Error::NotAllowed
    # Slack invites disabled in this environment — silent skip
  rescue => err
    report_slack_invite_failure(member, err)
  end

  def report_slack_invite_failure(member, error)
    failure_message = "#{error.class}: #{error.message}"
    Rails.logger.error(
      "[MemberSubscriber] Slack invite failed for #{member.email}: #{failure_message}"
    )

    begin
      ::Service::AuditLogger.log(
        log_type:      'member',
        event_type:    'slack_invite_failed',
        resource_type: 'Member',
        resource_id:   member.id,
        subject:       member,
        field_changes: {
          'slack_invite' => ['requested', "failed: #{failure_message}"]
        },
        slack_channel: ::Service::SlackConnector.logs_channel
      )
    rescue => audit_error
      Rails.logger.error(
        "[MemberSubscriber] Could not audit Slack invite failure for #{member.email}: " \
        "#{audit_error.class}: #{audit_error.message}"
      )
    end

    begin
      Honeybadger.notify(
        error,
        context: {
          event_type: 'slack_invite_failed',
          member_id: member.id.to_s,
          member_email: member.email
        }
      ) if defined?(Honeybadger)
    rescue => honeybadger_error
      Rails.logger.error(
        "[MemberSubscriber] Could not notify Honeybadger of Slack invite failure for " \
        "#{member.email}: #{honeybadger_error.class}: #{honeybadger_error.message}"
      )
    end
  end

  def send_google_invite(member)
    begin
      invite_gdrive(member.email)
      invite_gdrive_writer(member.email)
    rescue Error::NotAllowed
      # Google Drive invites disabled in this environment — silent skip
    rescue Error::Google::Share, Error::Google::Upload => err
      ::Service::SlackConnector.send_slack_message("Error sharing Member Resources folder with #{member.fullname}. Error: #{err}")
    end
  end

  def update_braintree_customer_info(member)
    if member.customer_id
      # ID followed by hash of the attributes to update
      # https://developers.braintreepayments.com/reference/request/customer/update/ruby
      connect_gateway.customer.update(member.customer_id, first_name: member.firstname, last_name: member.lastname)
    end
  end
end
