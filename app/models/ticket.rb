class Ticket
  def self.pull
    Counter.next_sequence_id("tickets")
  end
end
