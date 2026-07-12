class AdminController < ApplicationController
  before_action :authenticate_member!
  before_action :authorized?

  private
  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
  end
end
