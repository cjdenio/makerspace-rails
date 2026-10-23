class FixTicket
  include Mongoid::Document
  field :_id, type: FixTicketId, default: -> { Ticket.pull }
  # Private attribution; the presenter only exposes non-reporter closers.
  field :closed_by_id, type: BSON::ObjectId
  include Mongoid::Timestamps

  ACTIVE = %w[open in_progress waiting_for_parts].freeze
  STATUSES = (ACTIVE + %w[resolved rejected withdrawn]).freeze
  CONFIRMATIONS = %w[unverified confirmed could_not_confirm].freeze
  CATEGORIES = %w[damaged broken missing donation_offer other].freeze
  # Single-line names: keep free-form discussion in descriptions and notes.
  SAFE_NAME_PATTERN = '^[A-Za-z0-9 .,_()/\\-]+$'.freeze
  SAFE_NAME = /\A[A-Za-z0-9 .,_()\/-]+\z/.freeze
  SAFE_NAME_MESSAGE = 'may contain only ASCII letters, numbers, spaces, and . , _ ( ) / -'.freeze
  field :reporter_id, type: BSON::ObjectId
  # Persist consent at creation; changing category must never reveal a reporter.
  field :show_identity, type: Boolean, default: false
  field :title, type: String
  field :description, type: String
  field :category, type: String
  field :status, type: String, default: 'open'
  field :confirmation, type: String, default: 'unverified'
  field :shop_id, type: BSON::ObjectId
  field :tool_id, type: BSON::ObjectId
  field :uncatalogued_tool, type: String
  field :priority, type: Integer
  field :submitted_priority, type: Integer
  field :i_broke_it, type: Boolean, default: false
  field :i_can_fix_it, type: Boolean, default: false
  field :public_read_only, type: Boolean, default: false
  field :assignee_ids, type: Array, default: []
  field :manual_assignee_ids, type: Array, default: []
  field :bounty_assignee_ids, type: Array, default: []
  field :announce_to_slack, type: Boolean, default: false
  field :announcement_note, type: String, default: ''
  field :bounty_id, type: BSON::ObjectId
  field :reward_id, type: BSON::ObjectId
  field :revision, type: Integer, default: 0
  field :submission_key, type: String
  field :slack_ticket_ts, type: String
  field :slack_ticket_channel_id, type: String
  field :slack_ticket_team_id, type: String
  # Notification bookkeeping; updated directly without changing updated_at.
  field :delivery_job_id, type: String
  field :delivery_job_until, type: Time

  attr_readonly :reporter_id, :created_at, :submitted_priority, :submission_key
  validates :reporter_id, :title, :description, :submission_key, presence: true
  validates :title, length: { maximum: 150 }
  validates :title, format: { with: SAFE_NAME, message: SAFE_NAME_MESSAGE }, if: -> { new_record? || title_changed? }
  validates :uncatalogued_tool, format: { with: SAFE_NAME, message: SAFE_NAME_MESSAGE }, allow_blank: true,
    if: -> { new_record? || uncatalogued_tool_changed? }
  validates :description, length: { maximum: 10000 }
  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :confirmation, inclusion: { in: CONFIRMATIONS }
  validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
  index({ reporter_id: 1, submission_key: 1 }, unique: true)
  index({ reporter_id: 1, status: 1, priority: 1 })
  index({ assignee_ids: 1, status: 1 })
  index({ public_read_only: 1, status: 1 })
  index({ shop_id: 1, tool_id: 1, status: 1 })
  index({ priority: 1, created_at: 1 })
  index({ updated_at: -1 })

  def active? = ACTIVE.include?(status)
  def shop = Shop.where(id: shop_id).first
  def tool = Tool.where(id: tool_id).first
  def bounty = VolunteerTask.where(id: bounty_id).first
  def public_locked? = bounty && %w[available claimed pending].include?(bounty.status)
end
