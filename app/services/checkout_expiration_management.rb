class CheckoutExpirationManagement
  def self.parse_date(value)
    return nil if value.nil?
    raise ArgumentError unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    Date.iso8601(value)
  rescue ArgumentError
    raise Error::UnprocessableEntity.new('Expiration must be a valid YYYY-MM-DD date or null for Never')
  end

  def self.authorize!(actor, tool)
    raise Error::Forbidden.new('You cannot manage checkout expirations for this tool') unless
      tool && ToolGroup.manageable_by?(actor, tool.shop_id)
  end

  def self.update!(actor:, checkout:, expires_on:, revision:)
    date = parse_date(expires_on)
    authorize!(actor, checkout.tool)
    CatalogMutationLock.with([checkout.tool.shop_id]) do
      CheckoutMutationLock.with(member_id: checkout.member_id, tool_id: checkout.tool_id) do
        checkout.reload
        authorize!(actor.reload, checkout.tool)
        raise Error::Conflict.new('This checkout changed. Refresh before saving.') unless
          revision.to_s.match?(/\A\d+\z/) && checkout.expiration_revision == revision.to_i
        ToolCheckout.with_session do |session|
          session.with_transaction do
            checkout.reload
            raise Error::Conflict.new('This checkout changed. Refresh before saving.') unless checkout.expiration_revision == revision.to_i
            change!(actor, checkout, date)
          end
        ensure
          session.end_session
        end
      end
    end
    refresh(checkout.tool)
    checkout
  end

  def self.bulk_update!(actor:, tool:, expires_on:)
    date = parse_date(expires_on)
    raise Error::UnprocessableEntity.new('Choose an expiration date later than today') unless
      date && date > Time.current.in_time_zone(CheckoutExpiration::ZONE).to_date
    authorize!(actor, tool)
    count = 0
    CatalogMutationLock.with_persistent(tool.shop_id) do |assert_owned|
      authorize!(actor.reload, tool.reload)
      ToolCheckout.with_session do |session|
        session.with_transaction do
          assert_owned.call
          count = 0
          # Query inside every transaction attempt: concurrent revocations cause
          # a write conflict and a retry sees the new current set. Catalog writers
          # (approvals, renewals and date edits) share the persistent catalog key.
          ToolCheckout.current_checkouts.where(tool_id: tool.id).each do |row|
            change!(actor, row, date)
            count += 1
          end
          assert_owned.call
        end
      ensure
        session.end_session
      end
    end
    refresh(tool)
    count
  end

  def self.change!(actor, checkout, date)
    raise Error::Conflict.new('Only current, non-revoked checkouts can be edited') unless checkout.current_checkout?
    return if checkout.expires_on == date
    before = checkout.expires_on
    checkout.update!(expires_on: date, expiration_revision: checkout.expiration_revision + 1, expiration_notice_state: {})
    # Persist the audit with the mutation; no external messages inside the transaction.
    Service::AuditLogger.log(log_type: 'member', event_type: 'tool_checkout_expiration_changed',
      resource_type: 'ToolCheckout', resource_id: checkout.id, actor: actor, subject: checkout.member,
      field_changes: { 'expires_on' => [before&.iso8601, date&.iso8601] }) || raise('Could not persist checkout expiration audit')
  end

  def self.refresh(tool)
    CheckoutCreation.notify { ToolCheckoutSlackCanvasSyncJob.perform_later(tool.shop_id.to_s) }
  end
  private_class_method :change!, :refresh
end
