class FixTicketsController < ApplicationController
  wrap_parameters false
  before_action :authenticate_member!
  # Do not persist the reporter/request correlation in the shared Slack audit queue.
  skip_after_action :send_messages
  before_action { response.set_header('Cache-Control', 'private, no-store') }
  # Override the shared handler, which logs current_member alongside the ticket
  # URL. Normal ticket errors must not create a reporter identity side channel.
  rescue_from Error::CustomError do |error|
    render json: { error: error.message }, status: error.error
  end
  rescue_from Mongoid::Errors::Validations do |error|
    render json: { error: error.document.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  def index
    render json: FixTicketQuery.call(current_member, params.permit(:mode, :shop_id, :tool_id, :priority, :category, :confirmation, :assignee_id, :sort, :direction, :page, :page_size, statuses: []))
  end
  def catalog
    privileged = %w[admin board_member].include?(current_member.role)
    shops = FixTicketService.catalog_shops(current_member)
    tools = FixTicketService.catalog_tools(current_member)
    eligible = current_member.fully_active_unexpired?
    open_count = FixTicketService.count(current_member)
    can_create = eligible && (privileged || open_count < FixTicketService.limit)
    reason = !eligible ? 'Reporting requires active, unexpired membership.' : (!can_create ? "You have reached the open-ticket limit (#{FixTicketService.limit}). Withdraw or close a report before submitting another." : nil)
    # distinct(:assignee_ids) on tickets that all have an empty assignee_ids
    # array returns [BSON::Undefined] rather than [] -- passing that into a
    # $in clause raises "InMatchExpression equality cannot be undefined".
    assignee_ids = FixTicketPolicy.new(current_member).scope.distinct(:assignee_ids).select { |id| id.is_a?(BSON::ObjectId) }
    render json: { shops: shops.map { |s| { id: s.id.to_s, name: s.name } },
      tools: tools.map { |t| { id: t.id.to_s, name: t.name, shopId: t.shop_id.to_s, outOfService: !!t.out_of_service } },
      assignees: Member.where(:id.in => assignee_ids).order_by(lastname: :asc).map { |m| { id: m.id.to_s, name: m.fullname } },
      canCreate: can_create, creationUnavailableReason: reason,
      openCount: open_count, openLimit: privileged ? nil : FixTicketService.limit,
      bountyMaxCredit: VolunteerTask.ticket_bounty_max_credit,
      centralSlackEnabled: SystemConfig.slack_tickets_channel.present? }
  end
  def show
    render_ticket(find_ticket, detail: true)
  end
  def create
    render_ticket(FixTicketService.create!(actor: current_member, attributes: body), detail: true)
  end
  def update
    render_ticket(FixTicketService.update!(id: params[:id], actor: current_member, attributes: body), detail: true)
  end
  def notes
    render_ticket(FixTicketService.note!(id: params[:id], actor: current_member, note: params[:note], respond_as: params[:respond_as]), detail: true)
  end
  def withdraw
    render_ticket(FixTicketService.withdraw!(id: params[:id], actor: current_member), detail: true)
  end
  def assignments
    render_ticket(FixTicketService.assign!(id: params[:id], actor: current_member, member_ids: params[:member_ids], unassign_self: params[:unassign_self] == true), detail: true)
  end
  def assignee_options
    ticket = find_ticket
    raise Error::Forbidden.new unless FixTicketPolicy.new(current_member, ticket).staff?
    query = Member.where(status: 'activeMember', :expirationTime.gt => Time.current.to_i * 1000)
    term = params[:search].to_s.strip
    query = query.any_of({ firstname: /#{Regexp.escape(term)}/i }, { lastname: /#{Regexp.escape(term)}/i }) if term.present?
    render json: query.order_by(lastname: :asc).limit(50).map { |m| { id: m.id.to_s, name: m.fullname } }
  end
  def bounty
    render_ticket(FixTicketService.bounty!(id: params[:id], actor: current_member, attributes: body), detail: true)
  end
  def reward
    raise Error::UnprocessableEntity.new('Choose approve or reject') unless %w[approve reject].include?(params[:decision])
    render_ticket(FixTicketService.review_reward!(id: params[:id], actor: current_member, approve: params[:decision] == 'approve'), detail: true)
  end
  def reveal
    ticket = find_ticket
    raise Error::Forbidden.new unless current_member.role == 'admin' && params[:acknowledged] == true
    response.set_header('Cache-Control', 'no-store')
    FixTicketReveal.create!(ticket_id: ticket.id, admin_id: current_member.id)
    audit = Service::AuditLogger.log(log_type: 'portal', event_type: 'ticket_reporter_revealed',
      resource_type: 'FixTicket', resource_id: ticket.id, actor: current_member,
      after_snapshot: { ticket_id: ticket.id.to_s, title: ticket.title },
      message_details: "Ticket ##{ticket.id}: #{ticket.title}")
    raise Error::ServiceUnavailable.new('Unable to audit this reveal. Please retry.') unless audit
    member = Member.where(id: ticket.reporter_id).first
    render json: { name: member&.fullname || 'Former member', id: member&.id&.to_s }
  end
  def retry_delivery
    raise Error::Forbidden.new unless FixTicketPolicy.new(current_member, find_ticket).staff?
    FixTicketService.enqueue(find_ticket)
    render json: { queued: true }
  end
  def outage
    ticket = find_ticket
    raise Error::Forbidden.new unless FixTicketPolicy.new(current_member, ticket).staff? && ticket.tool
    render json: ToolAvailabilityService.set!(tool: ticket.tool, actor: current_member, value: params[:out_of_service])
  end
  private
  def find_ticket
    ticket = FixTicket.where(id: FixTicketId.mongoize(params[:id])).first
    raise Error::NotFound.new unless ticket && FixTicketPolicy.new(current_member, ticket).read?
    ticket
  end
  def body = params.except(:controller, :action, :id, :format).permit!.to_h
  def render_ticket(ticket, detail: false)
    render json: FixTicketPresenter.ticket(ticket, current_member, detail: detail)
  end
end
