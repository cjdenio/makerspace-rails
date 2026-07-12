class VolunteerEventSerializer < ActiveModel::Serializer
  attributes :id,
             :event_number,
             :title,
             :description,
             :credit_value,
             :event_date,
             :status,
             :created_by_id,
             :closed_by_id,
             :closed_at,
             :attendee_ids,
             :attendee_removals,
             :created_at,
             :updated_at

  attribute :attendee_count do
    object.attendee_count
  end

  attribute :created_by_name do
    object.created_by&.fullname
  rescue
    nil
  end

  attribute :closed_by_name do
    object.closed_by&.fullname
  rescue
    nil
  end

  attribute :attendee_names do
    object.attendee_ids.map do |member_id|
      Member.find(member_id)&.fullname rescue nil
    end.compact
  rescue
    []
  end
end
