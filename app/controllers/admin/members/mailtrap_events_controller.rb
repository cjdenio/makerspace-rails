class Admin::Members::MailtrapEventsController < AdminOrRmController
  before_action :authorized?
  before_action :find_member

  # GET /api/admin/members/:member_id/mailtrap_events
  def index
    events = MailtrapEvent
      .where(member_id: @member.id)
      .order_by(occurred_at: :desc)
      .limit(100)

    # Eager-load associated MailtrapMessage records to avoid N+1
    message_ids = events.map(&:mailtrap_message_id).compact
    messages_by_id = MailtrapMessage
      .where(:id.in => message_ids)
      .each_with_object({}) { |m, h| h[m.id] = m }

    render json: events.map { |event|
      msg = messages_by_id[event.mailtrap_message_id]
      {
        id:                  event.id.to_s,
        occurred_at:         event.occurred_at,
        status:              event.status,
        event_type:          event.event,
        email:               event.email,
        message_id:          event.message_id,
        sending_domain_name: event.sending_domain_name,
        sending_stream:      event.sending_stream,
        # From MailtrapMessage if available
        subject:             msg&.subject,
        mailer_class:        msg&.mailer_class,
        action:              msg&.action
      }
    }, status: :ok
  end

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
  end

  def find_member
    @member = Member.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
  end
end
