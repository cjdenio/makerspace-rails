# Read-only, request-local data for an authorized ticket page or detail.
# Never retain this context across mutations or transaction retries.
class FixTicketContext
  attr_reader :approver, :events

  def initialize(tickets, viewer_policy, events: [])
    @approver = viewer_policy.approver
    @events = events
    @tools = load(Tool, tickets.map(&:tool_id) + events.flat_map { |event| Array(event.field_changes['tool_id']) })
    @shops = load(Shop, tickets.map(&:shop_id) + @tools.values.map(&:shop_id) + events.flat_map { |event| Array(event.field_changes['shop_id']) })
    @bounties = load(VolunteerTask, tickets.map(&:bounty_id))
    @rewards = load(VolunteerCredit, tickets.map(&:reward_id))
    @members = load(Member, tickets.flat_map(&:assignee_ids) + tickets.map(&:closed_by_id) + tickets.select(&:show_identity).map(&:reporter_id) + events.map(&:actor_id))
  end

  def shop(ticket) = @shops[ticket.shop_id.to_s]
  def tool(ticket) = @tools[ticket.tool_id.to_s]
  def shop_by_id(id) = @shops[id.to_s]
  def tool_by_id(id) = @tools[id.to_s]
  def bounty(ticket) = @bounties[ticket.bounty_id.to_s]
  def reward(ticket) = @rewards[ticket.reward_id.to_s]
  def member_name(id) = @members[id.to_s]&.fullname || 'Former member'

  private

  def load(model, ids)
    ids = ids.compact.uniq
    ids.empty? ? {} : model.where(:id.in => ids).to_a.index_by { |record| record.id.to_s }
  end
end
