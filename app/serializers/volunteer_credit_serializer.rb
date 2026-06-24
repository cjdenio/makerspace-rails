class VolunteerCreditSerializer < ActiveModel::Serializer
  attributes :id,
             :member_id,
             :issued_by_id,
             :task_id,
             :description,
             :credit_value,
             :status,
             :discount_applied,
             :discount_applied_at,
             :reversed,
             :reversal_of_id,
             :reversal_reason,
             :reversed_by_id,
             :reversed_at,
             :created_at,
             :updated_at

  attribute :member_name do
    object.member&.fullname
  rescue
    nil
  end

  attribute :issued_by_name do
    object.issued_by&.fullname
  rescue
    nil
  end

  attribute :task_title do
    object.task&.title
  rescue
    nil
  end

  attribute :reversed_by_name do
    Member.find(object.reversed_by_id)&.fullname if object.reversed_by_id
  rescue
    nil
  end
end
