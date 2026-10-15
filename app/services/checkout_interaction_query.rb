# Short-lived lookup data for one portal response or Slack interaction.
class CheckoutInteractionQuery
  COLLATION = { locale: "en", strength: 2 }.freeze

  def initialize(member:, shop: nil)
    @member, @shop = member, shop
  end

  def enabled_shops
    Shop.where(:disabled.ne => true).collation(COLLATION).order_by(name: :asc, id: :asc)
  end

  def groups
    criteria = ToolGroup.where(archived: false, :shop_id.in => enabled_shops.pluck(:id))
    criteria = criteria.where(shop_id: @shop.id) if @shop
    criteria.order_by(name: :asc).collation(COLLATION).to_a
  end

  def requestable_groups
    groups.select do |group|
      begin
        review = ToolGroupCheckout.review(member: @member, group: group, requesting: true)
        review[:create_tool_ids].any? && review[:missing_prerequisite_ids].empty? &&
          !ToolCheckoutRequest.where(member_id: @member.id, tool_group_id: group.id, status: 'open').exists?
      rescue Error::UnprocessableEntity
        false
      end
    end
  end

  def volunteerable_groups
    groups.select do |group|
      begin
        ToolGroupVolunteering.eligible!(@member, group)
        !CheckoutApprover.find_by(member_id: @member.id)&.can_approve_group?(group) &&
          !CheckoutApproverRequest.where(member_id: @member.id, tool_group_id: group.id, status: 'open').exists?
      rescue Error::UnprocessableEntity
        false
      end
    end
  end

  def visible_group_requests
    allowed = groups.select { |group| ToolGroupCheckout.authorized?(@member, group) }.map(&:id)
    ToolCheckoutRequest.where(status: 'open', :tool_group_id.in => groups.map(&:id)).any_of(
      { member_id: @member.id }, { :tool_group_id.in => allowed }).to_a.select do |request|
        begin
          ToolGroupCheckout.validate_review!(ToolGroupCheckout.review(member: request.member, group: request.tool_group))
          true
        rescue Error::UnprocessableEntity
          false
        end
      end.sort_by { |request| request.target.name.downcase }
  end

  def visible_group_volunteers
    allowed = groups.select { |group| CheckoutApproverVolunteering.reviewer?(@member, group.shop_id) }.map(&:id)
    CheckoutApproverRequest.where(status: 'open', :tool_group_id.in => allowed).to_a
  end

  def requestable_tools
    candidates = tools.where(:disabled.ne => true, :open.ne => true)
      .collation(COLLATION).order_by(name: :asc, id: :asc).includes(:shop).to_a
    checkouts = ToolCheckout.where(member_id: @member.id).pluck(:tool_id, :revoked_at)
    existing_ids = checkouts.map { |id, _| id.to_s }.to_set
    active_ids = checkouts.filter_map { |id, revoked| id.to_s if revoked.nil? }.to_set
    request_ids = ToolCheckoutRequest.where(member_id: @member.id, status: "open").pluck(:tool_id).map(&:to_s).to_set
    candidates.select do |tool|
      ToolCheckoutRequestEligibility.new(member: @member, tool: tool,
        checkout_tool_ids: existing_ids, active_checkout_tool_ids: active_ids,
        open_request_tool_ids: request_ids).eligible?
    end
  end

  def active_checkouts
    ToolCheckout.where(member_id: @member.id, revoked_at: nil, :tool_id.in => tools.pluck(:id))
  end

  def listed_active_checkouts
    return [] if SlackCheckoutModal.membership_error(@member)
    ordered_tools = listing_tools.collation(COLLATION).order_by(name: :asc, id: :asc).includes(:shop).to_a
      .reject { |tool| tool.shop.nil? || tool.shop.disabled? }
    rows = ToolCheckout.where(member_id: @member.id, revoked_at: nil, :tool_id.in => ordered_tools.map(&:id)).to_a
      .group_by(&:tool_id)
    ordered_tools.flat_map do |tool|
      Array(rows[tool.id]).sort_by { |row| row.id.to_s }.each { |row| row.tool = tool }
    end
  end

  def visible_open_requests
    ids = open_requests.pluck(:id) | open_requests(for_approval: true).pluck(:id)
    rows = ToolCheckoutRequest.where(status: "open", :id.in => ids, :tool_id.in => listing_tools.pluck(:id))
      .order_by(request_date: :asc, id: :asc).includes(:member, tool: :shop).to_a
    checkouts = ToolCheckout.where(:member_id.in => rows.map(&:member_id).uniq)
      .pluck(:member_id, :tool_id, :revoked_at).group_by(&:first)
    rows.select do |row|
      next false unless row.member && row.tool
      records = checkouts.fetch(row.member_id, [])
      ToolCheckoutRequestEligibility.new(member: row.member, tool: row.tool,
        checkout_tool_ids: records.map { |_, tool_id, _| tool_id },
        active_checkout_tool_ids: records.filter_map { |_, tool_id, revoked| tool_id if revoked.nil? },
        open_request_tool_ids: []).eligible?
    end
  end

  def volunteerable_tools
    return [] unless @member.valid_for_checkout_request?
    checked_out_ids = active_checkouts.pluck(:tool_id)
    assigned_ids = CheckoutApprover.allowed_tool_ids_for_member(@member.id)
    requested_ids = CheckoutApproverRequest.where(member_id: @member.id, status: "open").pluck(:tool_id).map(&:to_s)
    tools.where(:id.in => checked_out_ids, :disabled.ne => true, :open.ne => true)
      .collation(COLLATION).order_by(name: :asc, id: :asc).to_a
      .reject { |tool| assigned_ids.include?(tool.id.to_s) || requested_ids.include?(tool.id.to_s) }
  end

  def visible_volunteer_requests
    return CheckoutApproverRequest.none unless @shop && CheckoutApproverVolunteering.reviewer?(@member, @shop.id)
    CheckoutApproverRequest.where(status: "open", :tool_id.in => tools.pluck(:id))
      .order_by(request_date: :asc, id: :asc).includes(:member, tool: :shop)
  end

  # Personal lists and approval queues are distinct authorization contexts.
  def open_requests(for_approval: false)
    visible_tools = for_approval ? approvable_tools : tools.where(:disabled.ne => true)
    tool_rows = visible_tools.pluck(:id, :allow_pending)
    members = for_approval ? Member.all : Member.where(id: @member.id)
    active_ids = members.where(status: "activeMember", :expirationTime.gt => Time.now.to_i * 1000).pluck(:id)
    pending_ids = members.where(status: "pending").pluck(:id)
    requests = ToolCheckoutRequest.where(status: "open", :tool_id.in => tool_rows.map(&:first))
    requests = requests.where(member_id: @member.id) unless for_approval
    requests.any_of(
      { :member_id.in => active_ids },
      { :member_id.in => pending_ids, :tool_id.in => tool_rows.filter_map { |id, pending| id if pending } }
    ).order_by(request_date: :asc, id: :asc).includes(:member, tool: :shop)
  end

  private

  def listing_tools
    scope = tools.where(:disabled.ne => true, :open.ne => true,
      :shop_id.in => enabled_shops.pluck(:id))
    @member.status == "pending" ? scope.where(allow_pending: true) : scope
  end

  def tools
    @shop ? Tool.where(shop_id: @shop.id) : Tool.all
  end

  def approvable_tools
    return tools if @member.role.in?(%w[admin board_member])

    managed_ids = @member.role == "resource_manager" ? Array(@member.resource_manager_shop_ids) : []
    approver = CheckoutApprover.find_by(member_id: @member.id) if @member.valid_for_checkout_request?
    tools.any_of(
      { :shop_id.in => managed_ids },
      { :shop_id.in => Array(approver&.shop_ids), :disabled.ne => true },
      { :id.in => Array(approver&.tool_ids), :disabled.ne => true }
    )
  end
end
