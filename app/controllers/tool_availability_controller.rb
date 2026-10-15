class ToolAvailabilityController < ApplicationController
  before_action :authenticate_member!
  def create
    tool = Tool.where(id: FixTicketService.parse_id(params[:id])).first
    raise Error::NotFound.new unless tool
    render json: ToolAvailabilityService.set!(tool: tool, actor: current_member, value: params[:out_of_service])
  end
end
