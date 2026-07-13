class RentalsController < AuthenticationController
  include FastQuery::MongoidQuery
  before_action :set_rental, only: [:show, :update, :cancel, :decline_agreement, :mark_vacated]

  def index
    @rentals = Rental.where(member_id: current_member.id)
    render_with_total_items(
      query_resource(@rentals),
      { each_serializer: RentalSerializer, adapter: :attributes }
    )
  end

  def show
    render json: @rental, adapter: :attributes
  end

  # POST /api/rentals — member claims a rental spot
  def create
    unless current_member.status == "activeMember"
      raise ::Error::Forbidden.new("Your membership is not active. Please renew before requesting a rental.")
    end

    past_due = Invoice.where(member_id: current_member.id, settled_at: nil, transaction_id: nil)
                      .select(&:past_due)
    if past_due.any?
      raise ::Error::Forbidden.new("You have outstanding past due invoices. Please settle your balance before requesting a rental.")
    end

    spot = RentalSpot.find(params[:rental_spot_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:rental_spot_id] }) if spot.nil?
    raise ::Error::UnprocessableEntity.new("This rental is not currently available.") unless spot.available?

    status = spot.requires_approval? ? "pending" : "pending_agreement"

    @rental = Rental.new(
      number:         spot.number,
      description:    spot.description,
      member_id:      current_member.id,
      status:         status,
      rental_spot_id: spot.id.to_s,
      notes:          params[:notes]
    )
    @rental.save!

    if spot.requires_approval?
      notify_admin_pending(@rental, spot)
    end

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'rental_requested',
      resource_type:  'Rental',
      resource_id:    @rental.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { number: @rental.number, status: @rental.status,
                        rental_spot_id: @rental.rental_spot_id }
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes, status: 201
  end

  # PUT /api/rentals/:id — member signs rental agreement
  def update
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental agreement cannot be signed at this stage.") unless @rental.status == "pending_agreement"

    encoded_signature = update_params[:signature]&.split(",")&.[](1)
    if encoded_signature
      DocumentUploadJob.perform_later(encoded_signature, "rental_agreement", @rental.id.as_json)
      @rental.update_attributes!(
        contract_signed_date: Date.today,
        status: "active"
      )

      # Generate invoice after agreement signed
      # Use rental_spot_id if available, otherwise fall back to number-based lookup
      spot = @rental.rental_spot
      if spot.nil? && @rental.number.present?
        spot = RentalSpot.find_by(number: @rental.number)
      end

      if spot&.invoice_option.present?
        spot.invoice_option.build_invoice(current_member.id, Time.now, @rental.id.to_s)
      end

      member = current_member
      profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/invoices"

      slack_user = SlackUser.find_by(member_id: member.id)
      unless slack_user.nil?
        enque_message("You've signed your rental agreement for *#{@rental.number}*! ⚠ Your rental is not valid until payment is received. Please pay your invoice here: #{profile_url}", slack_user.slack_id)
      end

      RentalMailer.rental_claimed(member.id.to_s, @rental.id.to_s).deliver_later

      ::Service::AuditLogger.log(
        log_type:       'member',
        event_type:     'rental_agreement_signed',
        resource_type:  'Rental',
        resource_id:    @rental.id,
        actor:          current_member,
        subject:        current_member,
        after_snapshot: { number: @rental.number, status: @rental.status,
                          contract_signed_date: @rental.contract_signed_date.to_s }
      )
    end

    render json: @rental, adapter: :attributes
  end

  # DELETE /api/rentals/:id/decline_agreement — member declines rental agreement
  def decline_agreement
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental is not pending agreement.") unless @rental.status == "pending_agreement"

    @rental.update_attributes!(
      status: "agreement_denied",
      notes: [@rental.notes, "Agreement declined by member on #{Date.today}"].compact.join(" | ")
    )

    member = current_member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental claim for *#{@rental.number}* has been cancelled because the rental agreement was not signed.",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.decline_agreement.member.#{@rental.id}")
      )
    end
    enque_message(
      "❌ #{member.fullname} declined the rental agreement for *#{@rental.number}*. Rental voided.",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.decline_agreement.management.#{@rental.id}")
    )

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'rental_agreement_declined',
      resource_type:  'Rental',
      resource_id:    @rental.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { number: @rental.number, status: @rental.status }
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  # DELETE /api/rentals/:id/cancel
  def cancel
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental is already cancelled.") if ["cancelled", "agreement_denied"].include?(@rental.status)

    vacated = params[:vacated].to_s == "true"

    if @rental.subscription_id.present?
      begin
        gateway = ::Service::BraintreeGateway.connect_gateway
        ::BraintreeService::Subscription.cancel(gateway, @rental.subscription_id)
      rescue => err
        Rails.logger.error("Error cancelling Braintree subscription for rental #{@rental.id}: #{err}")
      end
    end

    if vacated
      active_invoice = Invoice.active_invoice_for_resource(@rental.id)
      active_invoice&.destroy
      @rental.update_attributes!(status: "cancelled")
      notify_rental_ended(@rental)
    else
      @rental.update_attributes!(status: "vacating")
      expiry = @rental.expiration ? Time.at(@rental.expiration / 1000).strftime("%B %-d, %Y") : "the end of your current rental period"
      notify_rental_vacating(@rental, expiry)
    end

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'rental_cancelled',
      resource_type:  'Rental',
      resource_id:    @rental.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { number: @rental.number, status: @rental.status, vacated: vacated }
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  # POST /api/rentals/:id/mark_vacated — member or admin marks a vacating rental as vacated
  def mark_vacated
    unless @rental.member_id.to_s == current_member.id.to_s || is_admin? || is_board_member? || is_resource_manager?
      raise ::Error::Forbidden.new
    end
    raise ::Error::UnprocessableEntity.new("Rental is not in vacating status.") unless @rental.status == "vacating"

    active_invoice = Invoice.active_invoice_for_resource(@rental.id)
    active_invoice&.destroy

    @rental.update_attributes!(status: "cancelled")
    notify_rental_ended(@rental)

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'rental_vacated',
      resource_type:  'Rental',
      resource_id:    @rental.id,
      actor:          current_member,
      subject:        @rental.member,
      after_snapshot: { number: @rental.number, status: @rental.status }
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  private

  def set_rental
    @rental = Rental.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Rental, { id: params[:id] }) if @rental.nil?
  end

  def update_params
    params.require(:signature)
    params.permit(:signature)
  end

  def notify_admin_pending(rental, spot)
    member = current_member
    host = Rails.configuration.action_mailer.default_url_options[:host]
    admin_rentals_url = "#{host}/admin/rentals"
    admin_message = "🔔 New rental request from *#{member.fullname}* for *#{spot.number}* (#{spot.rental_type&.display_name} — #{spot.location}). <#{admin_rentals_url}|Review rental requests>"
    enque_message(
      admin_message,
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.notify_admin_pending.management.#{rental.id}")
    )

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental request for *#{spot.number}* has been received and is pending admin approval. You will be notified once reviewed.",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.notify_admin_pending.member.#{rental.id}")
      )
    end

    RentalMailer.rental_request_pending(member.id.to_s, rental.id.to_s, spot.id.to_s).deliver_later
  end

  def notify_rental_ended(rental)
    member = rental.member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental of *#{rental.number}* has ended. The space is now available for other members.",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.notify_rental_ended.member.#{rental.id}")
      )
    end
    enque_message(
      "🔴 #{member.fullname}'s rental of *#{rental.number}* has been cancelled.",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.notify_rental_ended.management.#{rental.id}")
    )
    RentalMailer.rental_ended(member.id.to_s, rental.id.to_s).deliver_later
  end

  def notify_rental_vacating(rental, expiry)
    member = rental.member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental of *#{rental.number}* will end on #{expiry}. Please ensure you have vacated by then.",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.notify_rental_vacating.member.#{rental.id}")
      )
    end
    enque_message(
      "🟡 #{member.fullname}'s rental of *#{rental.number}* is vacating — expires #{expiry}.",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.notify_rental_vacating.management.#{rental.id}")
    )
    RentalMailer.rental_vacating(member.id.to_s, rental.id.to_s, expiry).deliver_later
  end
end
