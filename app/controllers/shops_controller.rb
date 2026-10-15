class ShopsController < ApplicationController
  before_action :authenticate_member!

  def index
    shops = Shop.all.order_by(name: :asc).to_a
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes, sheet_viewer: current_member,
      checkout_context: CheckoutReadContext.for_shops(shops)
  end
end
