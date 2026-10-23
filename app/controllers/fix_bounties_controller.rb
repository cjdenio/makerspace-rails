class FixBountiesController < ApplicationController
  before_action :authenticate_member!
  before_action { response.set_header('Cache-Control', 'private, no-store') }
  def show
    task = VolunteerTask.where(id: FixTicketService.parse_id(params[:id])).first
    raise Error::NotFound.new unless task
    ticket = FixTicket.where(id: task.ticket_id).first
    allowed = current_member.fully_active_unexpired? || (ticket && FixTicketPolicy.new(current_member, ticket).read?)
    raise Error::Forbidden.new unless allowed
    render json: task, serializer: FixBountySerializer, adapter: :attributes, scope: current_member
  end
end
