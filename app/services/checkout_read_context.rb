# One response/job's lookup data. Never cache this across requests: assignments,
# checkouts and tool notes can change independently of the catalog.
class CheckoutReadContext
  attr_reader :tools, :shops, :members, :checked_out_tool_ids, :tool_groups

  def initialize(viewer = nil)
    @viewer = viewer
    @tools, @shops, @members, @names, @counts, @resource_managers = {}, {}, {}, {}, {}, {}
    @tool_groups = {}
    @checked_out_tool_ids = Set.new
    if viewer
      @approver = CheckoutApprover.find_by(member_id: viewer.id)
      @checked_out_tool_ids = ToolCheckout.where(member_id: viewer.id, revoked_at: nil)
        .pluck(:tool_id).map(&:to_s).to_set
    end
  end

  def self.for_tools(tools, viewer)
    new(viewer).load_tools(tools)
  end

  def self.for_shops(shops)
    context = new
    context.load_shops(shops)
    context.load_catalog(shops: shops)
    context.load_resource_managers(shops.map(&:id))
    context
  end

  def self.for_checkouts(checkouts, viewer)
    context = for_tools(Tool.where(:id.in => checkouts.map(&:tool_id).uniq).to_a, viewer)
    context.load_members(checkouts.flat_map { |row| [row.member_id, row.approved_by_id] })
    context
  end

  def self.for_approvers(approvers)
    context = new
    context.load_members(approvers.map(&:member_id))
    context.load_shops(Shop.where(:id.in => approvers.flat_map(&:shop_ids).uniq).only(:name).to_a)
    context.load_tool_details(approvers.flat_map(&:tool_ids).uniq)
    context.load_group_details(approvers.flat_map(&:tool_group_ids).uniq)
    context
  end

  def load_tools(tools)
    @tools = tools.index_by { |tool| tool.id.to_s }
    load_shops(Shop.where(:id.in => tools.map(&:shop_id).uniq).to_a)
    load_names(tools.flat_map { |tool| Array(tool.prerequisite_ids) + tool.effective_reservation_prerequisite_ids })
    self
  end

  def load_shops(shops)
    @shops = shops.index_by { |shop| shop.id.to_s }
  end

  def load_members(ids)
    @members = Member.where(:id.in => ids.compact.uniq).only(:firstname, :lastname, :email)
      .index_by { |member| member.id.to_s }
  end

  def load_names(ids)
    @names = Tool.where(:id.in => ids.uniq).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  # Approver-scoped tool detail (name/shop/out_of_service), batched to avoid
  # a per-approver query. Reuses the same @tools store as load_tools, and
  # populates @names from the same result instead of a second Tool query.
  def load_tool_details(ids)
    @tools = Tool.where(:id.in => ids.uniq).only(:name, :shop_id, :out_of_service).index_by { |tool| tool.id.to_s }
    @names = @tools.transform_values(&:name)
  end

  def load_group_details(ids)
    return if ids.empty?
    @tool_groups = ToolGroup.where(:id.in => ids).only(:name, :shop_id).index_by { |group| group.id.to_s }
  end

  def groups_for(ids)
    Array(ids).map(&:to_s).filter_map { |id| tool_groups[id] }
  end

  def tools_for(ids)
    Array(ids).map(&:to_s).filter_map { |id| tools[id] }
  end

  # Batched to avoid a per-shop query in ShopSerializer#resource_managers.
  def load_resource_managers(shop_ids)
    ids = shop_ids.map(&:to_s).uniq
    @resource_managers = ids.index_with { [] }
    Member.shop_resource_manager_candidates.where(:resource_manager_shop_ids.in => ids)
      .only(:firstname, :lastname, :resource_manager_shop_ids).each do |member|
        Array(member.resource_manager_shop_ids).map(&:to_s).each do |shop_id|
          (@resource_managers[shop_id] ||= []) << { id: member.id.to_s, name: member.fullname } if ids.include?(shop_id)
        end
      end
  end

  def resource_managers_for(shop)
    @resource_managers.fetch(shop.id.to_s, nil)
  end

  # Counts and prerequisite labels share a single bounded catalog scan.
  # Use Mongoid's selector to cast stored IDs before passing it to the driver.
  def load_catalog(shops:)
    shop_ids = shops.map(&:id)
    prerequisite_ids = shops.flat_map { |shop| Array(shop.reservation_prerequisite_tool_ids) }
    selector = Tool.any_of({ :shop_id.in => shop_ids }, { :id.in => prerequisite_ids }).selector
    result = Tool.collection.aggregate([
      { '$match' => selector },
      { '$facet' => {
        'counts' => [{ '$match' => Tool.where(:shop_id.in => shop_ids).selector },
                     { '$group' => { '_id' => '$shop_id', 'count' => { '$sum' => 1 } } }],
        'names' => [{ '$match' => Tool.where(:id.in => prerequisite_ids).selector },
                    { '$project' => { '_id' => 1, 'name' => 1 } }]
      } }
    ]).first || {}
    @counts = result.fetch('counts', []).to_h { |row| [row['_id'].to_s, row['count']] }
    @names = result.fetch('names', []).to_h { |row| [row['_id'].to_s, row['name']] }
  end

  def names(ids)
    wanted = Array(ids).map(&:to_s).to_set
    @names.filter_map { |id, name| name if wanted.include?(id) }
  end

  def shop_names(ids)
    wanted = Array(ids).map(&:to_s).to_set
    shops.filter_map { |id, shop| shop.name if wanted.include?(id) }
  end

  def tool_count(shop)
    @counts.fetch(shop.id.to_s, 0)
  end

  # Match Tool#notes_visible_to? without a database query for each row.
  def notes_visible?(tool)
    @viewer.present? && (@viewer.role.in?(%w[admin board_member]) ||
      @viewer.manages_shop?(tool.shop_id) || @approver&.can_approve_tool?(tool) ||
      checked_out_tool_ids.include?(tool.id.to_s))
  end

  # Match the Slack command's stricter approval eligibility, distinct from notes.
  def can_approve?(tool)
    @viewer.present? && (@viewer.role.in?(%w[admin board_member]) ||
      @viewer.manages_shop?(tool.shop_id) ||
      (!tool.disabled? && @viewer.valid_for_checkout_request? && @approver&.can_approve_tool?(tool)))
  end

  def can_generate_checkout_required_sheet?(tool)
    @sheet_policy ||= CheckoutRequiredSheetPolicy.new(@viewer, approver: @approver)
    @sheet_policy.allowed?(tool, shop: shops[tool.shop_id.to_s])
  end
end
