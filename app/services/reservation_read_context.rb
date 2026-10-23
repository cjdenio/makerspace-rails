require "set"

# One modal build or reservation evaluation only. Never retain across requests,
# or carry a preview's data into a create/update lock.
class ReservationReadContext
  attr_reader :shop, :member

  def initialize(shop: nil, member: nil, resources: [])
    @shop, @member = shop, member
    @tool_names = {}
    @invoice_options = {}
    remember_tools(resources.reject { |resource| resource.is_a?(Shop) })
  end

  def candidate_tools
    @candidate_tools ||= Tool.where(shop_id: shop.id, reservable: true, :disabled.ne => true, :out_of_service.ne => true)
      .order_by(name: :asc).to_a.tap { |tools| remember_tools(tools) }
  end

  def eligible_tools(through: nil)
    if through
      return ReservationPolicy.eligible_tools(
        shop: shop, member: member, tools: candidate_tools, read_context: self, through: through
      )
    end
    @eligible_tools ||= ReservationPolicy.eligible_tools(
      shop: shop, member: member, tools: candidate_tools, read_context: self
    )
  end

  def checked_out_tool_ids(through: nil)
    return valid_through_tool_ids(through) if through

    @checked_out_tool_ids ||= valid_through_tool_ids(nil)
  end

  def checkouts
    @checkouts ||= ToolCheckout.current_checkouts.where(member_id: member.id).to_a
  end

  def valid_through_tool_ids(at)
    checkouts.select { |checkout| at ? checkout.valid_through?(at) : checkout.active? }.map { |checkout| checkout.tool_id.to_s }.to_set
  end

  def checkout_expirations(ids)
    checkouts.select { |checkout| ids.include?(checkout.tool_id.to_s) && checkout.expires_on }.map do |checkout|
      "#{tool_names(ids)[checkout.tool_id.to_s]} (expires #{checkout.expires_on.iso8601})"
    end
  end

  def tool_names(ids)
    ids = Array(ids).map(&:to_s).uniq
    missing = ids.reject { |id| @tool_names.key?(id) }
    if missing.any?
      # Remember absent records too, so repeated labels do not repeat queries.
      missing.each { |id| @tool_names[id] = nil }
      remember_tools(Tool.where(:id.in => missing).only(:name).to_a)
    end
    @tool_names.slice(*ids)
  end

  def invoice_options(ids)
    ids = Array(ids).map(&:to_s).uniq
    missing = ids.reject { |id| @invoice_options.key?(id) }
    if missing.any?
      missing.each { |id| @invoice_options[id] = nil }
      InvoiceOption.where(:id.in => missing, resource_class: "fee", disabled: false)
        .only(:name, :amount).each { |option| @invoice_options[option.id.to_s] = option }
    end
    @invoice_options.slice(*ids)
  end

  private

  def remember_tools(tools)
    tools.each { |tool| @tool_names[tool.id.to_s] = tool.name }
  end
end
