# New repair tickets use sequence numbers; existing ObjectId links remain valid.
class FixTicketId
  def self.mongoize(value)
    return nil if value.nil?
    return value if value.is_a?(BSON::ObjectId)
    text = value.to_s.delete_prefix('#')
    return text.to_i if text.match?(/\A[1-9][0-9]*\z/) && text.to_i <= 9_223_372_036_854_775_807
    return BSON::ObjectId.from_string(text) if BSON::ObjectId.legal?(text)
    raise Error::UnprocessableEntity.new('Invalid ticket number')
  end

  def self.demongoize(value) = mongoize(value)
  def self.evolve(value) = mongoize(value)
end
