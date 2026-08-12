class Card
  include Mongoid::Document
  field :uid #Member's CardID as string
  field :holder, type: String #Member's name
  field :expiry, type: Integer #Member's expirationTime
  field :validity, type: String #Member's Status
  attr_accessor :card_location

  before_create :set_expiration, :set_holder
  before_update :set_expiration
  after_create :activate_pending_member, :update_rejection_card, :settle_open_member_invoices, :enqueue_member_provisioning
  after_update :enqueue_member_provisioning

  validates :uid, presence: true, uniqueness: true

  index({ uid: 1 }, {
    unique: true,
    partial_filter_expression: { uid: { '$type' => 'string' } }
  })

  belongs_to :member, class_name: 'Member', inverse_of: :access_cards

  @@memberStatuses = {
    active: "activeMember",
    revoked: "revoked",
    nonMember: "nonMember",
    lost: "lost",
    stolen: "stolen",
    suspended: "suspended",
    expired: "expired"
  }

  @@activeStatuses = [
    @@memberStatuses[:active],
    @@memberStatuses[:nonMember],
    @@memberStatuses[:expired],
  ]

  def is_active?
    @@activeStatuses.include?(self.validity)
  end

  def invalidate
    self.card_location = @@memberStatuses[:lost]
    self.save!
  end

  private
  def activate_pending_member
    return unless member&.status == 'pending'

    member.set(status: 'activeMember')
    set(validity: 'activeMember') if validity == 'pending'
  end

  def set_holder
    self.holder = self.member.fullname
  end

  def set_expiration
    self.expiry = self.member.expirationTime
    if (!!self.card_location)
      self.validity = self.card_location
    elsif (self.validity != @@memberStatuses[:lost] && self.validity != @@memberStatuses[:stolen])
      self.validity = self.member.status
    end
  end

  def update_rejection_card
    rejection_card = RejectionCard.find_by(uid: self.uid)
    rejection_card.update_attributes!(holder: self.member.fullname) unless rejection_card.nil?
  end

  def settle_open_member_invoices
    if self == self.member.access_cards.first
      open_invoices = self.member.invoices.where(:transaction_id.nin => ["", nil], settled_at: nil)
      open_invoices.each { |i| i.send(:execute_invoice_operation) }
    end
  end

  def enqueue_member_provisioning
    MemberProvisioningJob.perform_later(member_id.to_s)
  end
end
