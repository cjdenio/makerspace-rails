class WorkshopsController < ApplicationController
  before_action :authenticate_member!

  def index
    workshops = is_admin? || is_board_member? ? AvailableShopCache.load_all : AvailableShopCache.load_visible

    render json: {
      canAddShop: is_admin? || is_board_member?,
      workshops: ActiveModelSerializers::SerializableResource.new(
        workshops,
        each_serializer: WorkshopSerializer,
        adapter: :attributes,
        scope: current_member,
        sheet_policy: CheckoutRequiredSheetPolicy.new(current_member,
          approver: CheckoutApprover.find_by(member_id: current_member.id))
      ).as_json
    }
  end
end
