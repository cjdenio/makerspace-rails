class WorkshopsController < ApplicationController
  before_action :authenticate_member!

  def index
    workshops = Shop.all
    workshops = workshops.where(:disabled.ne => true) unless is_admin? || is_board_member?
    workshops = workshops.order_by(name: :asc)

    render json: {
      canAddShop: is_admin? || is_board_member?,
      workshops: ActiveModelSerializers::SerializableResource.new(
        workshops,
        each_serializer: WorkshopSerializer,
        adapter: :attributes,
        scope: current_member
      ).as_json
    }
  end
end
