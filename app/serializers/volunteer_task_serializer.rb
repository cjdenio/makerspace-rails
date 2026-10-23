class VolunteerTaskSerializer < ActiveModel::Serializer
  def visibility = @visibility ||= VolunteerTaskVisibility.new(object, scope)
  def shop_id = visibility.shop&.id
  def prerequisite_tool_ids = visibility.prerequisite_tools.map { |tool| tool.id.to_s }
  def created_by_id = visibility.creator_id
  def ticket_id = object.ticket_id&.to_s
  attributes :id,
             :ticket_id,
             :task_number,
             :title,
             :description,
             :credit_value,
             :shop_id,
             :prerequisite_tool_ids,
             :status,
             :days,
             :next_available,
             :parent_task_id,
             :created_by_id,
             :claimed_by_id,
             :claimed_at,
             :completed_at,
             :verified_by_id,
             :rejection_reason,
             :created_at,
             :updated_at

  attribute :shop_name do
    visibility.shop&.name
  rescue
    nil
  end

  attribute :prerequisite_tool_names do
    visibility.prerequisite_tools.map(&:name)
  rescue
    []
  end

  attribute :claimed_by_name do
    object.claimed_by&.fullname
  rescue
    nil
  end

  attribute :created_by_name do
    Member.where(id: created_by_id).first&.fullname if created_by_id
  rescue
    nil
  end

  attribute :verified_by_name do
    object.verified_by&.fullname
  rescue
    nil
  end

  attribute :is_child_task do
    object.child_task?
  end

  attribute :is_cooling_down do
    object.currently_cooling_down?
  end
end
