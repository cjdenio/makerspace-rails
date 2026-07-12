class GroupSerializer < ActiveModel::Serializer
  attributes :id,
             :group_name,
             :group_rep,
             :expiry,
             :primary_member,
             :secondary_members

  def group_name
    object.groupName
  end

  def group_rep
    object.groupRep
  end

  def primary_member
    m = object.member
    return nil unless m
    { id: m.id.to_s, firstname: m.firstname, lastname: m.lastname, email: m.email }
  end

  def secondary_members
    object.active_members
          .where(:id.ne => object.groupName)
          .map do |m|
      { id: m.id.to_s, firstname: m.firstname, lastname: m.lastname, email: m.email }
    end
  end
end
