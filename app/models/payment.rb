class Payment
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  belongs_to :member, optional: true
  after_initialize :find_member

  field :product
  field :firstname
  field :lastname
  field :amount, type: Float
  field :currency
  field :status
  field :payment_date
  field :payer_email
  field :address
  field :txn_id
  field :txn_type
  field :plan_id
  field :test, type: Boolean

  validates :txn_id, uniqueness: true, :allow_blank => true, :allow_nil => true

  private
  def configure_subscription_status
    rental_product_match = /(plot|rental|locker)/i.match(self.product)
    unless rental_product_match
      true_types = ['subscr_signup', 'subscr_payment']
      false_types = ['subscr_eot', 'subscr_cancel', 'subscr_failed']
      #use specific false types so other donations/payments don't invalidate subscription
      if true_types.include?(self.txn_type)
          self.member.subscription = true
      elsif false_types.include?(self.txn_type)
          self.member.subscription = false
      end
      self.member.save
    end
  end

  def find_member
    unless !!self.member
      # Use direct field queries instead of Member.search (which requires Atlas Search index)
      self.member = Member.find_by(email: self.payer_email.to_s.downcase) unless self.payer_email.nil?
      self.member ||= Member.where(lastname: /\A#{Regexp.escape(self.lastname)}\z/i).first unless self.lastname.nil?
      self.member ||= Member.where(firstname: /\A#{Regexp.escape(self.firstname)}\z/i).first unless self.firstname.nil?
      if !self.member && self.payer_email then
        payments = Payment.where(member: !nil, payer_email: self.payer_email.to_s.downcase).order_by(payment_date: :desc);
        self.member = payments.first.member unless payments.empty?
      end
      self.save
    end

    if self.member
      configure_subscription_status
    end
  end
end
