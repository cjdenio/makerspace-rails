class Admin::RentalsController < AdminController
  include FastQuery::MongoidQuery
  before_action :authorized?
  before_action :set_rental, only: [:update, :destroy, :approve, :deny]

  def index
    rentals = Rental.all

    if search_params[:member_id].present?
      rentals = rentals.where(member_id: search_params[:member_id])
    end

    if search_params[:status].present?
      rentals = rentals.where(status: search_params[:status])
    end

    render_with_total_items(
      query_resource(rentals),
      { each_serializer: RentalSerializer, adapter: :attributes }
    )
  end

  def create
    @rental = Rental.new(create_rental_params)
    @rental.status = "active"
    @rental.save!

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'rental_created', resource_type: 'Rental',
      resource_id: @rental.id, actor: current_member, subject: @rental.member,
      field_changes: @rental.previous_changes, before_snapshot: {},
      after_snapshot: @rental.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    # Generate invoice for admin-created rentals
    spot = @rental.rental_spot
    if spot.nil? && @rental.number.present?
      spot = RentalSpot.find_by(number: @rental.number)
    end

    if spot&.invoice_option.present?
      member_id = @rental.member_id.to_s
      spot.invoice_option.build_invoice(member_id, Time.now, @rental.id.to_s)

      member = @rental.member
      if member
        profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/invoices"
        slack_user = SlackUser.find_by(member_id: member.id)
        unless slack_user.nil?
          enque_message("An admin has created a rental of *#{@rental.number}* for you. ⚠ Your rental is not valid until payment is received. Please pay your invoice here: #{profile_url}", slack_user.slack_id)
        end
        RentalMailer.rental_claimed(member.id.to_s, @rental.id.to_s).deliver_later
      end
    end

    render json: @rental, adapter: :attributes
  end

  def update
    initial_date = @rental.get_expiration
    before = @rental.attributes.dup
    @rental.update_attributes!(update_rental_params)
    notify_renewal(initial_date)
    @rental.reload

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'rental_updated', resource_type: 'Rental',
      resource_id: @rental.id, actor: current_member, subject: @rental.member,
      field_changes: @rental.previous_changes, before_snapshot: before,
      after_snapshot: @rental.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: @rental, adapter: :attributes
  end

  def destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?

    before = @rental.attributes.dup
    member = @rental.member

    # Cancel Braintree subscription if present
    if @rental.subscription_id.present?
      begin
        gateway = ::Service::BraintreeGateway.connect_gateway
        ::BraintreeService::Subscription.cancel(gateway, @rental.subscription_id)
      rescue => err
        Rails.logger.error("Error cancelling Braintree subscription for rental #{@rental.id}: #{err}")
      end
    end

    # Cancel any unpaid invoices
    active_invoice = Invoice.active_invoice_for_resource(@rental.id)
    active_invoice&.destroy

    @rental.update_attributes!(status: "cancelled")

    member = @rental.member
    if member
      enque_message(
        "🔴 Admin cancelled *#{member.fullname}*'s rental of *#{@rental.number}*.",
        ::Service::SlackConnector.members_relations_channel,
        ::Service::SlackConnector.request_caller_id("rentals.destroy.management.#{@rental.id}")
      )
      slack_user = SlackUser.find_by(member_id: member.id)
      unless slack_user.nil?
        enque_message(
          "An admin has cancelled your rental of *#{@rental.number}*. If you have questions please contact us.",
          slack_user.slack_id,
          ::Service::SlackConnector.request_caller_id("rentals.destroy.member.#{@rental.id}")
        )
      end
      RentalMailer.rental_ended(member.id.to_s, @rental.id.to_s).deliver_later
    end

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'rental_cancelled', resource_type: 'Rental',
      resource_id: before['_id'], actor: current_member, subject: member,
      field_changes: {}, before_snapshot: before,
      after_snapshot: {}, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204
  end

  # POST /api/admin/rentals/:id/approve
  def approve
    raise ::Error::UnprocessableEntity.new("Rental is not pending approval.") unless @rental.status == "pending"

    @rental.update_attributes!(status: "pending_agreement")

    member = @rental.member
    host = Rails.configuration.action_mailer.default_url_options[:host]
    profile_url = "#{host}/members/#{member.id}/rentals"

    enque_message(
      "✅ *#{member.fullname}*'s rental request for *#{@rental.number}* has been approved — awaiting agreement signature.",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.approve.management.#{@rental.id}")
    )

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental request for *#{@rental.number}* has been approved! Please visit your profile to sign the rental agreement: #{profile_url}",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.approve.member.#{@rental.id}")
      )
    end

    RentalMailer.rental_request_approved(member.id.to_s, @rental.id.to_s).deliver_later

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'rental_approved', resource_type: 'Rental',
      resource_id: @rental.id, actor: current_member, subject: member,
      field_changes: @rental.previous_changes, before_snapshot: { status: 'pending' },
      after_snapshot: @rental.reload.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  # POST /api/admin/rentals/:id/deny
  def deny
    raise ::Error::UnprocessableEntity.new("Rental is not pending approval.") unless @rental.status == "pending"

    reason = params[:reason].presence || "Your rental request was not approved at this time."
    @rental.update_attributes!(
      status: "denied",
      notes:  [@rental.notes, "Denied: #{reason}"].compact.join(" | ")
    )

    member = @rental.member
    enque_message(
      "❌ *#{member.fullname}*'s rental request for *#{@rental.number}* has been denied.",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rentals.deny.management.#{@rental.id}")
    )

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message(
        "Your rental request for *#{@rental.number}* was not approved. Reason: #{reason}",
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rentals.deny.member.#{@rental.id}")
      )
    end

    RentalMailer.rental_request_denied(member.id.to_s, @rental.id.to_s, reason).deliver_later

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'rental_denied', resource_type: 'Rental',
      resource_id: @rental.id, actor: current_member, subject: member,
      field_changes: @rental.previous_changes, before_snapshot: { status: 'pending' },
      after_snapshot: @rental.reload.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_resource_manager?
  end

  def set_rental
    @rental = Rental.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Rental, { id: params[:id] }) if @rental.nil?
  end

  def create_rental_params
    params.require([:number, :member_id])
    params.permit(:number, :member_id, :expiration, :description, :contract_on_file, :notes, :rental_spot_id)
  end

  def update_rental_params
    params.permit(:number, :member_id, :expiration, :description, :renew, :contract_on_file, :notes, :status)
  end

  def search_params
    params.permit(:member_id, :status, :search)
  end

  def notify_renewal(init)
    final = @rental.get_expiration
    if final && (init.nil? || (Time.at(final / 1000) - Time.at((init || 0) / 1000) > 1.day))
      @rental.send_renewal_slack_message(current_member)
    end
  end
end
