# Shared by the download endpoint and authenticated catalog capabilities.
# Supply the request's approver and shop lookups when serializing collections.
class CheckoutRequiredSheetPolicy
  def initialize(member, approver: nil)
    @member = member
    @approver = approver
  end

  def authorized?(resource, shop: resource.is_a?(Shop) ? resource : resource.shop)
    return false unless @member && shop
    return true if @member.role.in?(%w[admin board_member]) || @member.manages_shop?(shop.id)

    resource.is_a?(Tool) && @member.valid_for_checkout_request? &&
      !!@approver&.can_approve_tool?(resource)
  end

  def available?(resource, shop: resource.is_a?(Shop) ? resource : resource.shop)
    shop.present? && !shop.disabled? && !resource.disabled? &&
      !(resource.is_a?(Tool) && resource.open)
  end

  def allowed?(resource, shop: resource.is_a?(Shop) ? resource : resource.shop)
    authorized?(resource, shop: shop) && available?(resource, shop: shop)
  end
end
