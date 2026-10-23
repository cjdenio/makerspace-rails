class FixTicketQuery
  def self.call(member, parameters)
    p = parameters.to_h.stringify_keys
    mode = p.fetch('mode', 'all')
    raise Error::UnprocessableEntity.new('Invalid list') unless %w[all mine assigned queue public].include?(mode)
    policy = FixTicketPolicy.new(member)
    scope = policy.scope(mode)
    statuses = p.key?('statuses') ? Array(p['statuses']) : FixTicket::ACTIVE
    raise Error::UnprocessableEntity.new('Invalid statuses') if (statuses - FixTicket::STATUSES).any?
    scope = scope.where(:status.in => statuses)
    %w[shop_id tool_id].each do |key|
      next if p[key].blank?
      scope = scope.where(key => (p[key] == 'none' ? nil : FixTicketService.parse_id(p[key])))
    end
    if p['priority'].present?
      value = p['priority']
      raise Error::UnprocessableEntity.new('Invalid priority') unless value == 'none' || value.to_s.match?(/\A(?:[1-9]|10)\z/)
      scope = scope.where(priority: value == 'none' ? nil : value.to_i)
    end
    { 'category' => FixTicket::CATEGORIES, 'confirmation' => FixTicket::CONFIRMATIONS }.each do |key, allowed|
      next if p[key].blank?
      raise Error::UnprocessableEntity.new("Invalid #{key}") unless allowed.include?(p[key])
      scope = scope.where(key => p[key])
    end
    scope = scope.where(assignee_ids: FixTicketService.parse_id(p['assignee_id'])) if p['assignee_id'].present?
    sort, direction = p.fetch('sort', 'priority'), p.fetch('direction', 'asc')
    raise Error::UnprocessableEntity.new('Invalid ordering') unless %w[priority created_at updated_at].include?(sort) && %w[asc desc].include?(direction)
    page, size = Integer(p.fetch('page', 0)), Integer(p.fetch('page_size', 25))
    raise Error::UnprocessableEntity.new('Invalid page') unless page >= 0 && size.between?(1, 100)
    order = { sort => direction == 'asc' ? 1 : -1 }
    order['created_at'] = 1 if sort == 'priority'
    order['_id'] = 1
    pipeline = []
    pipeline << { '$addFields' => { 'priority_missing' => { '$cond' => [{ '$eq' => [{ '$ifNull' => ['$priority', nil] }, nil] }, 1, 0] } } } if sort == 'priority'
    order = { 'priority_missing' => 1 }.merge(order) if sort == 'priority'
    pipeline += [{ '$sort' => order }, { '$skip' => page * size }, { '$limit' => size }]
    page_result = FixTicket.collection.aggregate([
      { '$match' => scope.selector },
      { '$facet' => { 'tickets' => pipeline, 'total' => [{ '$count' => 'count' }] } }
    ]).first
    records = page_result.fetch('tickets').map { |row| FixTicket.instantiate(row.except('priority_missing')) }
    context = FixTicketContext.new(records, policy)
    { tickets: records.map { |ticket| FixTicketPresenter.ticket(ticket, member, context: context) }, total: page_result.dig('total', 0, 'count') || 0, page: page, pageSize: size }
  rescue ArgumentError, TypeError
    raise Error::UnprocessableEntity.new('Invalid pagination')
  end
end
