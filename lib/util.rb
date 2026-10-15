module Util
  def self.date_as_string(maybe_date)
    maybe_date.kind_of?(String) ? Date.parse(maybe_date).strftime("%m/%d/%Y") : maybe_date.strftime("%m/%d/%Y") 
  end

  def date_as_string(maybe_date)
    self.class.date_as_string(maybe_date)
  end
end