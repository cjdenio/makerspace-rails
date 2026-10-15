class ReservationGroupExpansion
  def self.call(source, reservation = nil)
    # Editing only times/title preserves the originally selected membership.
    legacy_unchanged = reservation && !source.key?(:tool_group_ids) &&
      Array(source[:tool_ids]).map(&:to_s).sort == Array(reservation.tool_ids).map(&:to_s).sort &&
      source.fetch(:shop_id, reservation.shop_id).to_s == reservation.shop_id.to_s &&
      source.fetch(:reservation_scope, reservation.reservation_scope) == reservation.reservation_scope
    if legacy_unchanged || (!source.key?(:tool_ids) && !source.key?(:tool_group_ids))
      return {
        tool_ids: Array(reservation&.tool_ids), tool_group_ids: Array(reservation&.tool_group_ids),
        selected_tool_ids: Array(reservation&.selected_tool_ids), group_snapshots: Array(reservation&.group_snapshots)
      }
    end
    ids = Array(source[:tool_group_ids]).map(&:to_s).uniq
    tools = Array(source[:tool_ids]).map(&:to_s).uniq
    groups = ToolGroup.where(:id.in => ids).to_a
    if groups.length != ids.length || groups.any? { |group| group.disabled? || !group.reservable? || group.shop_id.to_s != source[:shop_id].to_s }
      raise Error::UnprocessableEntity.new('One or more selected groups are unavailable')
    end
    raise Error::UnprocessableEntity.new('Groups require tool reservation scope') if ids.any? && source[:reservation_scope] != 'tools'
    snapshots = groups.map do |group|
      { 'id' => group.id.to_s, 'name' => group.name, 'revision' => group.revision,
        'tool_ids' => group.included_tool_ids, 'prerequisite_ids' => group.prerequisite_ids }
    end
    { tool_ids: (tools + groups.flat_map(&:included_tool_ids)).uniq, selected_tool_ids: tools,
      tool_group_ids: ids, group_snapshots: snapshots }
  end
end
