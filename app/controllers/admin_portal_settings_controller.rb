# app/controllers/admin_portal_settings_controller.rb
#
# Base controller for Portal Settings endpoints.
# Restricted to admin only — board_member does NOT have access.
#
class AdminPortalSettingsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorized?

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin?
  end
end
