class VolunteerTaskSerializer < ActiveModel::Serializer
  attributes :id,
             :task_number,
             :title,
             :description,
             :credit_value,
             :shop_id,
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
    object.shop&.name
  rescue
    nil
  end

  attribute :claimed_by_name do
    object.claimed_by&.fullname
  rescue
    nil
  end

  attribute :created_by_name do
    object.created_by&.fullname
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
