class Admin::RejectionsController < AuthenticationController
  def index
    rejections = RejectionCard.where(rejections_query).map(&:attributes)
    render json: { rejections: serialized_rejections(rejections) } and return
  end

  private

  def rejections_query
    query = { :uid.in => permitted_query_uids }
    if query_start_time || query_end_time
      query[:timeOf] = {}
      query[:timeOf]['$gte'] = Time.at(query_start_time / 1000.0).utc if query_start_time
      query[:timeOf]['$lte'] = Time.at(query_end_time / 1000.0).utc if query_end_time
    end
    query
  end

  def serialized_rejections(rejections)
    return rejections if privileged_access?
    rejections.map { |rejection| redact_uid(rejection) }
  end

  def redact_uid(attributes)
    attributes = attributes.as_json if attributes.respond_to?(:as_json)
    attributes = attributes.to_h if attributes.respond_to?(:to_h)
    attributes = attributes.dup
    uid_key = attributes.key?('uid') ? 'uid' : :uid
    attributes[uid_key] = redacted_uid_digest(attributes[uid_key]) if attributes.key?(uid_key)
    attributes
  end

  # See Admin::CheckinsController#redacted_uid_digest — identical logic,
  # kept consistent across both endpoints so a member's UID redacts to the
  # same value whether viewed via checkins or rejections.
  def redacted_uid_digest(uid)
    require 'openssl'
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, uid.to_s)[0, 12]
  end

  def permitted_query_uids
    @permitted_query_uids ||= begin
      return query_uids if privileged_access?
      member_card_uids = current_member.access_cards.map { |card| card.uid.to_s }
      query_uids & member_card_uids
    end
  end

  def privileged_access?
    is_privileged?
  end

  def query_uids
    @query_uids ||= begin
      parsed = JSON.parse(params.require(:uids))
      raise Error::UnprocessableEntity.new('uids must be an array') unless parsed.is_a?(Array)
      parsed.map(&:to_s)
    end
  end

  def query_start_time
    return nil if params[:startTime].blank?
    params[:startTime].to_i
  end

  def query_end_time
    return nil if params[:endTime].blank?
    params[:endTime].to_i
  end
end
