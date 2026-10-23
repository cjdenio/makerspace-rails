# app/controllers/admin_or_rm_controller.rb
#
# Base controller for endpoints that are accessible to admins, board members,
# and resource managers. Currently used by:
#   - Admin::InvoicesController  (RM limited to resource_class: "fee")
#   - Admin::InvoiceOptionsController  (RM limited to resource_class: "fee")
#
# Full admin-only endpoints remain under AdminController.
#
class AdminOrRmController < ApplicationController
  before_action :authenticate_member!
  before_action :authorized?

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || is_resource_manager?
  end
end
