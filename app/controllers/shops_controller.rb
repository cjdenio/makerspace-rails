class ShopsController < ApplicationController
  before_action :authenticate_member!

  def index
    shops = Shop.all.order_by(name: :asc)
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes
  end
end
