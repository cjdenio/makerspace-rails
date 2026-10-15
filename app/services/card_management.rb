require 'digest'

# Multi-document operations require a replica set. No unsafe standalone fallback.
class CardManagement
  class Conflict < StandardError; end
  class Unavailable < StandardError; end

  def self.reason(card, member = card.member)
    return 'Lost card' if card.validity == 'lost'
    return 'Assigned member is revoked' if member&.status == 'revoked'
    return 'Assigned member is expired' if member && (member.status == 'expired' ||
      (member.expirationTime.present? && member.expirationTime <= Time.current.to_i * 1000))
    nil
  end

  def self.version(card, member = card.member)
    Digest::SHA256.hexdigest([card.id.to_s, card.uid, card.member_id.to_s,
      card.validity, card.expiry, member&.status, member&.expirationTime].to_json)
  end

  def self.snapshot(card)
    member = card.member
    release_reason = reason(card, member)
    { id: card.id.to_s, uid: card.uid, holder: card.holder, expiry: card.expiry,
      validity: card.validity, member_id: card.member_id&.to_s,
      releasable: release_reason.present?, release_reason: release_reason,
      version: version(card, member) }
  end

  def self.transaction
    Card.with_session do |session|
      session.with_transaction { yield }
    ensure
      session.end_session
    end
  rescue Mongo::Error => error
    raise Conflict, 'This UID is already registered.' if error.respond_to?(:code) && error.code == 11000
    raise Unavailable, 'Card changes require an available MongoDB replica set. Please retry.'
  end

  def self.audit!(card, actor, event, before: nil, message_details: nil)
    log = Service::AuditLogger.log(log_type: 'member', event_type: event,
      resource_type: 'Card', resource_id: card.id, actor: actor, subject: card.member,
      before_snapshot: before, after_snapshot: event == 'card_released' ? {} : card.attributes,
      message_details: message_details)
    raise Unavailable, 'Unable to record the card audit. No changes were saved.' unless log
    log
  end

  def self.release!(id, expected_version, actor)
    member_id = nil
    transaction do
      card = Card.find(id)
      raise Error::NotFound.new unless card
      member = card.member
      raise Conflict, 'Card assignment changed. Scan the card again.' unless version(card, member) == expected_version
      raise Conflict, 'This card is not eligible for release.' unless reason(card, member)
      raise Conflict, 'Duplicate UID records require administrator repair.' unless Card.where(uid: card.uid).count == 1
      # A write to the member participates in transaction conflict detection with
      # renewals/revocations, even when their after_update card propagation is late.
      member.inc(card_operation_version: 1) if member
      member_id = member&.id&.to_s
      audit!(card, actor, 'card_released', before: card.attributes)
      RejectionCard.where(uid: card.uid).update_all(holder: nil)
      card.delete
    end
    MemberProvisioningJob.perform_later(member_id) if member_id
  end

  def self.assign!(attributes, actor, uid_source: nil)
    card = nil
    audit = nil
    transaction do
      member = Member.find(attributes[:member_id])
      raise Error::NotFound.new unless member
      member.inc(card_operation_version: 1)
      raise Conflict, 'This UID is already registered.' if Card.where(uid: attributes[:uid]).exists?
      card = Card.new(attributes)
      card.defer_assignment_effects = true
      card.save!
      member.access_cards.where(:id.ne => card.id, :validity.nin => %w[lost stolen]).each do |old|
        old.skip_provisioning_enqueue = true
        old.invalidate
      end
      card.finalize_assignment!
      # Source describes the client workflow, never authorization or UID validity.
      source_label = case uid_source
      when 'nfc' then 'NFC scan (client-reported)'
      when 'import' then 'Reader import (client-reported)'
      else 'Unspecified'
      end
      audit = audit!(card, actor, 'card_assigned', message_details: "Card UID source: #{source_label}")
    end
    # External provisioning and invoice callbacks must not run in a retried transaction.
    card.perform_assignment_effects!
    channel = Service::SlackConnector.logs_channel
    posted = Service::AuditLogger.attempt_slack(audit.slack_message, channel)
    audit.set(slack_channel: channel, slack_posted: posted)
    card
  end
end
