class Rental
  include Mongoid::Document
  include SanitizesUserInput
  include Mongoid::Search
  include InvoiceableResource
  include Service::SlackConnector
  include ActiveModel::Serializers::JSON
  include Publishable

  STATUSES = %w[pending pending_agreement active vacating cancelled denied agreement_denied].freeze

  belongs_to :member

  field :number
  field :description
  field :expiration,           type: Integer
  field :subscription_id,      type: String
  field :contract_signed_date, type: Date
  field :notes,                type: String
  field :status,               type: String, default: "active"
  field :rental_spot_id,       type: String

  search_in :number, member: %i[firstname lastname email]

  after_destroy :publish_destroy

  validates :number, presence: true, uniqueness: {
    conditions: -> { where(:status.in => ["active", "pending", "pending_agreement", "vacating"]) }
  }
  validates :status, inclusion: { in: STATUSES }

  def rental_spot
    return nil if rental_spot_id.blank?
    RentalSpot.find(rental_spot_id)
  rescue
    nil
  end

  def send_renewal_slack_message(current_user = nil)
    slack_user = SlackUser.find_by(member_id: member_id)
    # See Member#send_renewal_slack_message for why distinct uniquifiers
    # are required here — both calls share a method name and request_id,
    # so without this the second enque_message overwrites the first.
    unless slack_user.nil?
      enque_message(
        get_renewal_slack_message,
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.member.#{id}")
      )
    end
    enque_message(
      get_renewal_slack_message(current_user),
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.management.#{id}")
    )
  end

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(Rental))
    criteria.full_text_search(searchTerms)
  end

  def remove_subscription
    return unless subscription_id.present?

    expiry_str = expiration ?
      Time.at(expiration / 1000).strftime("%B %-d, %Y") :
      "the end of your current rental period"

    update_attributes!({ subscription_id: nil, status: "vacating" })

    m          = member
    slack_user = SlackUser.find_by(member_id: m.id) if m

    if slack_user
      ::Service::SlackConnector.send_slack_message(
        "Your rental of *#{number}* will end on #{expiry_str}. " \
        "Your subscription has been cancelled. Please ensure you have vacated by then.",
        slack_user.slack_id
      )
    end

    ::Service::SlackConnector.send_slack_message(
      "🟡 #{m&.fullname}'s rental of *#{number}* is vacating — " \
      "subscription cancelled, expires #{expiry_str}.",
      ::Service::SlackConnector.members_relations_channel
    )

    RentalMailer.rental_vacating(m.id.to_s, id.to_s, expiry_str).deliver_later if m
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def contract_on_file=(onFile)
    if onFile && contract_signed_date.nil?
      self.update_attributes!({ contract_signed_date: Date.today })
    elsif !onFile
      self.update_attributes!({ contract_signed_date: nil })
    end
  end

  protected

  def expiration_attr
    :expiration
  end

  def base_slack_message
    "#{self.member ? "#{self.member.fullname}'s rental of " : ""} # #{self.number}"
  end

  def publish_destroy
    publish(:destroy)
  end
end
