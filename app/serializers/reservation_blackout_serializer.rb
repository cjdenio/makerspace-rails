class ReservationBlackoutSerializer < ActiveModel::Serializer
  attributes :id, :title, :shop_id, :shop_name, :recurrence, :weekday,
             :start_time, :end_time, :start_date, :end_date,
             :created_by_id, :created_at, :updated_at

  def shop_name
    object.shop&.name
  end
end
