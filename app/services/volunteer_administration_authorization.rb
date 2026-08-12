class VolunteerAdministrationAuthorization
  GLOBAL_ROLES = %w[admin board_member].freeze

  def self.allowed?(member, shop_id)
    return false unless member
    return true if GLOBAL_ROLES.include?(member.role)

    member.role == 'resource_manager' && member.manages_shop?(shop_id)
  end
end
