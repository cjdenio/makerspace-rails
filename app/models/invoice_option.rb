class InvoiceOption
  include Mongoid::Document
  include Mongoid::Search
  include ActiveModel::Serializers::JSON

  PROMOTION_TIME_ZONE = "America/New_York".freeze

  ## Transaction Information
  # User friendly name for invoice displayed on receipt
  field :name, type: String
  # Any details about the invoice. Also shown on receipt
  field :description, type: String
  field :amount, type: Float
  # How many operations to perform (eg, num of months renewed)
  field :quantity, type: Integer
  # What does this do to Resource. One of Invoice::OPERATION_FUNCTIONS
  field :operation, type: String, default: "renew="
  # Class name of resource, one of OPERATION_RESOURCES
  field :resource_class, type: String
  # ID of billing plan to/is subscribe(d) to.  May reference a DEFAULT_INVOICE
  field :plan_id, type: String
  # ID of SSO discount that applies to this option
  field :discount_id, type: String

  field :disabled, type: Boolean, default: false
  field :promotion_end_date, type: DateTime

  search_in :name, :description

  validates :resource_class, inclusion: { in: Invoice::OPERATION_RESOURCES.keys }, allow_nil: false
  validates :operation, inclusion: { in: Invoice::OPERATION_FUNCTIONS }, allow_nil: false
  validates_numericality_of :amount, greater_than: 0
  validates_numericality_of :quantity, greater_than: 0
  validates_uniqueness_of :plan_id, unless: -> { plan_id.nil? }

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(InvoiceOption))
    criteria.full_text_search(searchTerms)
  end

  def self.signup_eligible(at: Time.current)
    local_date = at.in_time_zone(PROMOTION_TIME_ZONE).to_date
    promotion_cutoff = Time.utc(local_date.year, local_date.month, local_date.day)

    where(disabled: false, resource_class: "member")
      .where(plan_id: /\S/)
      .any_of(
        { promotion_end_date: nil },
        { :promotion_end_date.gte => promotion_cutoff }
      )
  end

  def promotion_active?(at: Time.current)
    promotion_end_date.present? &&
      promotion_end_date.to_date >= at.in_time_zone(PROMOTION_TIME_ZONE).to_date
  end

  def build_invoice(member_id, due_date, resource_id, discount = nil)
    amount = self.amount
    amount = amount - discount.amount.to_f unless discount.nil?
    invoice_args = {
      name: self.name,
      description: self.description,
      due_date: due_date,
      amount: amount,
      member_id: member_id,
      resource_id: resource_id,
      resource_class: self.resource_class,
      quantity: self.quantity,
      discount_id: discount ? discount.id : nil,
      plan_id: (self.plan_id.nil? || self.plan_id.empty?) ? nil : self.plan_id,
      operation: self.operation,
    }
    Invoice.create!(invoice_args)
  end
end
