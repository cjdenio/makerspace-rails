class Admin::GoogleCalendarController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_calendar_configuration

  def colors
    render json: {
      colors: Service::GoogleWorkspace.calendar_colors(
        include_color_id: params[:color_id]
      )
    }
  end

  private

  def authorize_calendar_configuration
    unless is_admin? || is_board_member? || is_resource_manager?
      raise ::Error::Forbidden.new("You are not authorized to configure shop reservation colors")
    end
  end
end
