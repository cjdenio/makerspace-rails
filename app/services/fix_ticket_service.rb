class FixTicketService
  CREATE_FIELDS = %w[title description category shop_id tool_id uncatalogued_tool priority public_read_only i_broke_it i_can_fix_it submission_key show_identity].freeze
  STAFF_FIELDS = %w[title description category shop_id tool_id uncatalogued_tool public_read_only announce_to_slack announcement_note].freeze
  class << self
    def limit = [SystemConfig.get('ticket_open_limit').to_i.nonzero? || 10, 1].max
    def count(member) = FixTicket.where(reporter_id: member.id, :status.in => FixTicket::ACTIVE).count
    def transaction(member_id, &block)
      # MongoDB transactions are required: never silently degrade atomic caps,
      # priorities, bounty publication or the notification outbox to best effort.
      FixTicket.with_session do |session|
        session.with_transaction do
          Member.collection.find(_id: member_id).update_one({ '$inc' => { 'fix_ticket_write_revision' => 1 } }, session: session)
          block.call
        end
      end
    rescue Mongo::Error::TransactionsNotSupported => error
      # Only this topology error is safe to expose verbatim. Do not turn other
      # database errors into public responses or retry these writes nonatomically.
      raise Error::ServiceUnavailable.new(
        "Repair ticket changes are unavailable. Configure MongoDB as a replica set " \
        "(a single-node replica set is sufficient for development/test) and update MLAB_URI. " \
        "MongoDB: #{error.message}"
      )
    end
    def capacity!(member)
      raise Error::Forbidden.new unless member&.fully_active_unexpired?
      return if %w[admin board_member].include?(member.role)
      n = count(member)
      raise Error::UnprocessableEntity.new("You have #{n} open tickets (limit #{limit}). Withdraw or close tickets before adding another.") if n >= limit
    end
    def parse_id(value)
      return nil if value.blank?
      raise Error::UnprocessableEntity.new('Invalid record ID') unless BSON::ObjectId.legal?(value.to_s)
      BSON::ObjectId.from_string(value.to_s)
    end
    def normalize(attributes)
      values = attributes.to_h.stringify_keys
      %w[shop_id tool_id].each { |key| values[key] = parse_id(values[key]) if values.key?(key) }
      %w[title description uncatalogued_tool announcement_note].each { |key| values[key] = values[key].to_s.strip if values.key?(key) }
      %w[public_read_only i_broke_it i_can_fix_it announce_to_slack].each do |key|
        next unless values.key?(key)
        raise Error::UnprocessableEntity.new("#{key} must be a boolean") unless [true, false].include?(values[key])
      end
      if values.key?('priority')
        value = values['priority']
        raise Error::UnprocessableEntity.new('Priority must be an integer from 1 to 10') unless value.blank? || value.to_s.match?(/\A(?:[1-9]|10)\z/)
        values['priority'] = value.blank? ? nil : value.to_i
      end
      values
    end
    def validate_catalog!(ticket)
      raise Error::UnprocessableEntity.new('Shop does not exist') if ticket.shop_id && !ticket.shop
      if ticket.tool_id
        raise Error::UnprocessableEntity.new('Choose a tool within the selected shop') unless ticket.tool && ticket.tool.shop_id == ticket.shop_id
        raise Error::UnprocessableEntity.new('Choose a catalog tool or an uncatalogued name, not both') if ticket.uncatalogued_tool.present?
      end
    end
    def catalog_shops(member)
      return Shop.all if %w[admin board_member].include?(member.role)
      managed = member.role == 'resource_manager' ? Array(member.resource_manager_shop_ids) : []
      Shop.any_of({ :disabled.ne => true }, { :id.in => managed })
    end
    def catalog_tools(member)
      tools = Tool.where(:shop_id.in => catalog_shops(member).pluck(:id))
      return tools if %w[admin board_member].include?(member.role)
      managed = member.role == 'resource_manager' ? Array(member.resource_manager_shop_ids) : []
      tools.any_of({ :disabled.ne => true }, { :shop_id.in => managed })
    end
    def create!(actor:, attributes:)
      attrs = normalize(attributes)
      raise Error::UnprocessableEntity.new('Unknown submission fields') if (attrs.keys - CREATE_FIELDS).any?
      attrs['show_identity'] = attrs['category'] == 'donation_offer' unless attrs.key?('show_identity')
      raise Error::UnprocessableEntity.new('show_identity must be a boolean') unless [true, false].include?(attrs['show_identity'])
      raise Error::UnprocessableEntity.new('Submission key is required') unless attrs['submission_key'].to_s.match?(/\A[\w-]{8,100}\z/)
      result = nil
      transaction(actor.id) do
        member = Member.find(actor.id)
        result = FixTicket.where(reporter_id: member.id, submission_key: attrs['submission_key']).first
        next if result
        capacity!(member)
        result = FixTicket.new(attrs.merge('reporter_id' => member.id, 'submitted_priority' => attrs['priority']))
        validate_catalog!(result)
        unless %w[admin board_member].include?(member.role) || member.manages_shop?(result.shop_id)
          raise Error::Forbidden.new('Catalog resource is unavailable') if result.shop&.disabled? || result.tool&.disabled?
        end
        result.valid? || raise(Error::UnprocessableEntity.new(result.errors.full_messages.join(', ')))
        if result.priority
          occupied = FixTicket.where(reporter_id: member.id, :status.in => FixTicket::ACTIVE, :priority.ne => nil).to_a.index_by(&:priority)
          slot, chain = result.priority, []
          while occupied[slot]
            chain << occupied[slot]
            slot += 1
          end
          chain.reverse_each do |other|
            other.update!(priority: other.priority == 10 ? nil : other.priority + 1)
          end
        end
        result.save!
        event!(result, member, 'created')
      end
      enqueue(result)
      result.reload
    end
    def mutate!(id:, actor:, revision: nil)
      initial = FixTicket.where(id: FixTicketId.mongoize(id)).first
      raise Error::NotFound.new unless initial
      result = nil
      canvas_shop_id = nil
      transaction(initial.reporter_id) do
        canvas_shop_id = nil
        result = FixTicket.find(initial.id)
        previous_bounty = [result.bounty_id, result.bounty&.status]
        previous_status = result.status
        actor = Member.find(actor.id)
        policy = FixTicketPolicy.new(actor, result)
        raise Error::NotFound.new unless policy.read?
        if revision && result.revision != revision.to_i
          raise Error::UnprocessableEntity.new('Ticket changed. Refresh before trying again.')
        end
        yield result, policy, actor
        if previous_status != result.status
          if result.active?
            result.update!(closed_by_id: nil)
          else
            result.update!(closed_by_id: actor.id)
            reporter_closed = actor.id == result.reporter_id
            # Database-only and fail-closed: rollback the closure if auditing fails.
            # Do not put reporter identity or request metadata in ordinary audit views.
            AuditLog.create!(log_type: 'portal', event_type: 'ticket_closed',
              resource_type: 'FixTicket', resource_id: result.id,
              actor_id: reporter_closed ? nil : actor.id,
              actor_name: reporter_closed ? 'Reporter' : actor.fullname,
              field_changes: { 'status' => [previous_status, result.status] },
              after_snapshot: { 'title' => result.title },
              slack_message: "Ticket ##{result.id}: #{result.title} closed as #{result.status}")
          end
        end
        # Recomputed on each transaction retry; enqueue only after commit.
        canvas_shop_id = result.shop_id if previous_bounty != [result.bounty_id, result.bounty&.reload&.status]
      end
      enqueue(result)
      enqueue_canvas(canvas_shop_id) if canvas_shop_id
      result.reload
    end
    def update!(id:, actor:, attributes:)
      attrs = attributes.to_h.stringify_keys
      revision = attrs.delete('revision')
      note = attrs.delete('note').to_s.strip
      respond_as = attrs.delete('respond_as')
      validate_note!(note) if note.present?
      nominate = attrs.delete('nominate_reward') == true
      raise Error::UnprocessableEntity.new('Priority cannot be changed after submission') if attrs.key?('priority')
      raise Error::UnprocessableEntity.new('Unknown update fields') if (attrs.keys - STAFF_FIELDS - %w[status confirmation]).any?
      mutate!(id: id, actor: actor, revision: revision) do |ticket, policy, member|
        raise Error::Forbidden.new if note.present? && !policy.note?
        note_role = note_role!(policy, respond_as) if note.present?
        raise Error::UnprocessableEntity.new('Notes must be at most 10000 characters') if note.length > 10000
        raise Error::Forbidden.new if (attrs.keys & STAFF_FIELDS).any? && !policy.staff?
        raise Error::Forbidden.new if (attrs.keys & %w[status confirmation]).any? && !policy.change_status?
        if attrs['public_read_only'] == false && ticket.public_locked?
          raise Error::UnprocessableEntity.new('This ticket must stay public while its bounty is active')
        end
        previous = ticket.status
        next_status = attrs['status'] || previous
        raise Error::UnprocessableEntity.new('Reporter rewards require resolution') if nominate && next_status != 'resolved'
        if next_status != previous
          raise Error::UnprocessableEntity.new('Use Withdraw to withdraw your own report') if next_status == 'withdrawn'
          if !ticket.active? && next_status != 'open'
            raise Error::UnprocessableEntity.new('Reopen the ticket before changing its status')
          end
          if %w[resolved rejected].include?(next_status) || !ticket.active?
            raise Error::UnprocessableEntity.new('A note is required') if note.blank?
          end
          if !ticket.active? && next_status == 'open'
            capacity!(Member.find(ticket.reporter_id))
          end
          ticket.priority = nil unless FixTicket::ACTIVE.include?(next_status) && ticket.active?
        end
        if attrs['confirmation'] == 'could_not_confirm' && ticket.confirmation != 'could_not_confirm' && note.blank?
          raise Error::UnprocessableEntity.new('A note is required when the issue could not be confirmed')
        end
        ticket.assign_attributes(normalize(attrs))
        if (attrs.keys & %w[shop_id tool_id]).any?
          raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).staff?
          raise Error::UnprocessableEntity.new('Cannot move a ticket with a linked bounty to another shop') if ticket.bounty && ticket.bounty.shop_id != ticket.shop_id
        end
        validate_catalog!(ticket)
        changes = ticket.changes.except('reporter_id', 'updated_at')
        ticket.save!
        cancel_unclaimed_bounty!(ticket) unless ticket.active?
        nominate_reward!(ticket, member) if nominate && next_status == 'resolved'
        event!(ticket, member, 'updated', note: note.presence, note_role: note_role, changes: changes) if changes.any? || note.present? || nominate
      end
    end
    def note!(id:, actor:, note:, respond_as: nil)
      validate_note!(note)
      mutate!(id: id, actor: actor) do |ticket, policy, member|
        raise Error::Forbidden.new unless policy.note?
        event!(ticket, member, 'note', note: note.strip, note_role: note_role!(policy, respond_as))
      end
    end
    def note_role!(policy, choice)
      if choice.present?
        return choice if (choice == 'reporter' && policy.reporter?) || (choice == 'assignee' && policy.assigned?)
        raise Error::UnprocessableEntity.new('Choose a response role you hold on this ticket')
      end
      raise Error::UnprocessableEntity.new('Choose Respond as: Assignee or Reporter') if policy.reporter? && policy.assigned?
      policy.reporter? ? 'reporter' : (policy.assigned? ? 'assignee' : nil)
    end
    def validate_note!(note)
      text = note.to_s.strip
      unless text.gsub(/[[:space:]\uFEFF]/, '').length >= 2 && text.length <= 10000
        raise Error::UnprocessableEntity.new('A note requires at least 2 non-whitespace characters and at most 10000 characters')
      end
    end
    def withdraw!(id:, actor:)
      mutate!(id: id, actor: actor) do |ticket, policy, member|
        raise Error::Forbidden.new unless policy.reporter? && ticket.active?
        previous = ticket.status
        ticket.update!(status: 'withdrawn', priority: nil)
        cancel_unclaimed_bounty!(ticket)
        event!(ticket, member, 'updated', changes: { 'status' => [previous, 'withdrawn'] })
      end
    end
    def assign!(id:, actor:, member_ids: nil, unassign_self: false)
      mutate!(id: id, actor: actor) do |ticket, policy, member|
        previous = ticket.assignee_ids.dup
        if unassign_self
          raise Error::Forbidden.new unless policy.assigned?
          ticket.manual_assignee_ids -= [member.id]
          ticket.bounty_assignee_ids -= [member.id]
        else
          raise Error::Forbidden.new unless policy.staff?
          ids = Array(member_ids).map { |value| parse_id(value) }.compact.uniq
          added = ids - previous
          members = Member.where(:id.in => added).to_a
          raise Error::UnprocessableEntity.new('New assignees must be active, unexpired members') unless members.length == added.length && members.all?(&:fully_active_unexpired?)
          # Retain explicit manual grants, but do not promote existing claim-only
          # access to a manual grant when staff submits the effective list.
          ticket.manual_assignee_ids = (ticket.manual_assignee_ids & ids) | (ids - ticket.bounty_assignee_ids)
          # Staff edits affect manual assignments only. Claim-derived access is
          # removed by release/rejection (or the participant's own unassignment).
        end
        ticket.assignee_ids = (ticket.manual_assignee_ids + ticket.bounty_assignee_ids).uniq
        next unless ticket.changed?
        ticket.save!
        assignment_event!(ticket, member, previous)
      end
    end
    def assignment_event!(ticket, actor, previous)
      event!(ticket, actor, 'assigned', added: ticket.assignee_ids - previous)
    end
    def cancel_unclaimed_bounty!(ticket)
      task = ticket.bounty
      task.update!(status: 'cancelled') if task&.status == 'available' && task.claimed_by_id.nil?
    end
    def bounty!(id:, actor:, attributes:)
      mutate!(id: id, actor: actor) do |ticket, policy, member|
        raise Error::Forbidden.new unless policy.bounty? && !policy.reporter? && ticket.active?
        next unless policy.bounty_replaceable?
        previous_bounty_id = ticket.bounty_id
        attrs = attributes.to_h.symbolize_keys.slice(:title, :description, :credit_value, :prerequisite_tool_ids)
        task = VolunteerTask.create!(attrs.merge(ticket_id: ticket.id, shop_id: ticket.shop_id, created_by_id: member.id, status: 'available'))
        ticket.update!(bounty_id: task.id, public_read_only: true)
        event!(ticket, member, 'bounty', changes: { 'bounty_id' => [previous_bounty_id, task.id] })
      end
    end
    def nominate_reward!(ticket, member)
      raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).bounty? && ticket.reporter_id != member.id
      return if ticket.reward_id
      credit = VolunteerCredit.create!(member_id: ticket.reporter_id, issued_by_id: member.id, ticket_id: ticket.id,
        description: 'Helpful tool report', credit_value: 1, status: 'pending')
      ticket.update!(reward_id: credit.id)
    end
    def review_reward!(id:, actor:, approve:)
      credit_id = nil
      result = mutate!(id: id, actor: actor) do |ticket, policy, member|
        credit = VolunteerCredit.where(id: ticket.reward_id).first
        raise Error::Forbidden.new unless policy.bounty? && credit && member.id != ticket.reporter_id && member.id != credit.issued_by_id
        next unless credit.status == 'pending'
        raise Error::UnprocessableEntity.new('The ticket must be resolved before reviewing its reporter reward') unless ticket.status == 'resolved'
        credit.update!(status: approve ? 'approved' : 'rejected', issued_by_id: member.id)
        credit_id = credit.id if approve
        event!(ticket, member, 'reward', changes: { 'reward' => [ 'pending', credit.status ] })
      end
      if credit_id
        credit = VolunteerCredit.find(credit_id)
        credit.send(:notify_member_credit_awarded)
        credit.send(:check_discount_threshold!)
      end
      result
    end
    def event!(ticket, actor, kind, note: nil, note_role: nil, changes: {}, added: [])
      ticket.inc(revision: 1)
      ticket.set(updated_at: Time.current)
      recipients = []
      recipients += ticket.assignee_ids - [actor.id] if kind == 'note' || note.present? || (changes.keys & %w[status confirmation]).any?
      recipients << ticket.reporter_id if actor.id != ticket.reporter_id && (kind == 'assigned' || note.present? || (changes.keys & %w[status confirmation assignees announcement_note]).any?)
      notify_staff = kind == 'created' || note.present?
      if notify_staff && ticket.shop_id.present?
        approver_rules = [{ shop_ids: ticket.shop_id.to_s }]
        approver_rules << { tool_ids: ticket.tool_id.to_s } if ticket.tool_id
        approver_ids = CheckoutApprover.any_of(*approver_rules).pluck(:member_id)
        candidates = Member.any_of({ role: 'resource_manager', resource_manager_shop_ids: ticket.shop_id.to_s }, { :id.in => approver_ids }).to_a
        # Match Policy#approver's first record even if legacy duplicate rows exist.
        approvers = CheckoutApprover.where(:member_id.in => candidates.map(&:id)).order_by(_id: :asc).to_a.reverse.index_by(&:member_id)
        tool = ticket.tool
        candidates.each do |candidate|
          next if candidate.id == actor.id
          rm = candidate.manages_shop?(ticket.shop_id)
          approver = candidate.valid_for_checkout_request? && approvers[candidate.id]
          relevant = approver && (tool ? approver.can_approve_tool?(tool) : approver.can_approve_for_shop?(ticket.shop_id))
          recipients << candidate.id if rm || relevant
        end
      end
      recipients += added
      recipients += [ticket.reporter_id] + ticket.assignee_ids if kind == 'bounty'
      FixTicketEvent.create!(ticket_id: ticket.id, actor_id: actor.id, kind: kind, note: note, note_role: note_role,
        unscoped_staff_notification: notify_staff && ticket.shop_id.blank?,
        field_changes: kind == 'assigned' ? changes.except('assignees') : changes, revision: ticket.revision, recipients: recipients.uniq)
    end
    def enqueue(ticket)
      FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    rescue StandardError => error
      Rails.logger.warn("Fix ticket delivery enqueue failed: #{error.class}")
    end
    def enqueue_canvas(shop_id)
      VolunteerSlackCanvasSyncJob.perform_later(shop_id.to_s)
    rescue StandardError => error
      Rails.logger.warn("Fix ticket canvas enqueue failed: #{error.class}")
    end
  end
end
