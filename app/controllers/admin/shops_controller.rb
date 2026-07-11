class Admin::ShopsController < AdminOrRmController
  before_action :find_shop, only: [:update, :destroy]

  def index
    shops = Shop.all.order_by(name: :asc)
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes
  end

  def create
    shop = Shop.new(shop_params)
    shop.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'shop_created',
      resource_type:  'Shop',
      resource_id:    shop.id,
      actor:          current_member,
      after_snapshot: shop.attributes
    )

    render json: shop, serializer: ShopSerializer, adapter: :attributes
  end

  def update
    before = @shop.attributes.dup
    @shop.update_attributes!(shop_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_updated',
      resource_type:   'Shop',
      resource_id:     @shop.id,
      actor:           current_member,
      field_changes:   @shop.previous_changes,
      before_snapshot: before,
      after_snapshot:  @shop.attributes
    )

    render json: @shop, serializer: ShopSerializer, adapter: :attributes
  end

  def destroy
    before = @shop.attributes.dup
    @shop.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_deleted',
      resource_type:   'Shop',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def shop_params
    params.permit(:name, :slack_channel, :disabled)
  end

  def find_shop
    @shop = Shop.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Shop, { id: params[:id] }) if @shop.nil?
  end
end
