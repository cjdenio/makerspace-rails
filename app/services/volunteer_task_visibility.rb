# Read-time catalog visibility shared by task feeds, details, and messages.
# Never alter stored prerequisites: hidden tools still gate eligibility.
class VolunteerTaskVisibility
  def initialize(task, viewer = nil)
    @task = task
    @policy = FixTicketPolicy.new(viewer)
  end

  def shop
    candidate = @task.shop
    candidate if @policy.catalog_shop_visible?(candidate)
  end

  def prerequisite_tools
    @prerequisite_tools ||= @task.prerequisite_tools.select { |tool| @policy.catalog_tool_visible?(tool, tool.shop) }
  end

  def creator_id
    return @task.created_by_id unless @task.ticket_id
    ticket = FixTicket.where(id: @task.ticket_id).first
    # Older bounties may predate the prohibition on reporter-created bounties.
    return nil unless ticket && ticket.reporter_id != @task.created_by_id
    @task.created_by_id
  end
end
