class Counter
  include Mongoid::Document

  store_in collection: "counter"

  field :seq, type: Integer

  def self.next_sequence_id(sequence_name)
    counter = where(_id: sequence_name).find_one_and_update(
      { "$inc" => { seq: 1 } },
      upsert: true,
      return_document: :after
    )

    counter.seq.to_i
  rescue Mongo::Error::OperationFailure => error
    raise unless error.code == 11_000 && where(_id: sequence_name).exists?

    retry
  end
end
