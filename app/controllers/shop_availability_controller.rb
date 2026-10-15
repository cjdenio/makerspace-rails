class ShopAvailabilityController < ApplicationController
  before_action :authenticate_member!

  def create
    shop = Shop.where(id: FixTicketService.parse_id(params[:id])).first
    raise Error::NotFound.new unless shop
    render json: ShopAvailabilityService.set!(shop: shop, actor: current_member,
      value: params[:out_of_service], note: params[:note])
  end
end
