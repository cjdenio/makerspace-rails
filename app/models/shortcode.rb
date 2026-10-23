class Shortcode
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: "shortcodes"

  field :code, type: String
  field :target_url, type: String
  index({ code: 1 }, unique: true)
  index({ target_url: 1 }, unique: true)
  validates :code, format: { with: /\A[2-9A-Z]{10}\z/ }
  validates :target_url, presence: true
  validate :immutable_mapping, on: :update

  def self.full_unique_index?(index, field)
    index["key"] == { field => 1 } && index["unique"] == true &&
      !index["sparse"] && !index["partialFilterExpression"]
  end

  def self.current_indexes
    collection.indexes.to_a
  rescue Mongo::Error::OperationFailure => error
    raise unless error.code == 26 # NamespaceNotFound on first use
    []
  end

  def self.ensure_indexes!
    indexes = current_indexes
    fields = %w[code target_url]
    # Check both fields before removing any protection. Never alter mappings to
    # make an index build succeed (including duplicate null/missing values).
    fields.each do |field|
      duplicates = collection.aggregate([
        { '$group' => { '_id' => "$#{field}", 'count' => { '$sum' => 1 } } },
        { '$match' => { 'count' => { '$gt' => 1 } } },
        { '$limit' => 1 }
      ]).to_a
      raise "Cannot create full unique index on shortcodes.#{field}: duplicate values" if duplicates.any?
    end
    fields.each do |field|
      indexes.each do |index|
        next unless index["key"] == { field => 1 } || index["name"] == "#{field}_1"
        next if full_unique_index?(index, field)
        Rails.logger.info("[ShortUrl] replacing incompatible index #{index['name']}")
        collection.indexes.drop_one(index.fetch("name"))
      end
    end
    create_indexes
  end

  private

  def immutable_mapping
    errors.add(:base, "Shortcode mappings are permanent") if code_changed? || target_url_changed?
  end
end
