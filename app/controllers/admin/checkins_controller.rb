class Admin::CheckinsController < AuthenticationController
  DEFAULT_LIMIT = 500

  def index
    checkins = checkins_collection.find(checkins_query).to_a
    # timeOf/time are stored inconsistently as seconds or milliseconds per
    # record (see CheckinTimeHelper), so a native Mongo sort on either raw
    # field would interleave them out of chronological order. Normalize in
    # Ruby before sorting/capping instead.
    checkins = checkins.sort_by { |checkin| -(CheckinTimeHelper.normalize_to_seconds(checkin['timeOf'].presence || checkin['time']) || 0) }
                        .first(result_limit)
    render json: { checkins: serialized_checkins(checkins) } and return
  end

  private

  def result_limit
    Integer(params[:limit] || DEFAULT_LIMIT).tap do |limit|
      raise ::Error::UnprocessableEntity.new("Limit must be a positive integer") unless limit.positive?
    end
  rescue ArgumentError, TypeError
    raise ::Error::UnprocessableEntity.new("Limit must be a positive integer")
  end

  def checkins_collection
    Mongoid.default_client[:checkins]
  end

  def checkins_query
    query = {}

    # Build time range — checks timeOf and time fields under BOTH unit
    # interpretations (seconds and milliseconds), since either field may
    # store either unit depending on the record. See CheckinTimeHelper.
    if query_start_time || query_end_time
      # Use $and to safely combine uid filter with $or time field conditions
      query['$and'] = [
        { 'uid' => { '$in' => permitted_query_uids } },
        { '$or' => CheckinTimeHelper.dual_unit_or_query(query_start_time, query_end_time) }
      ]
    else
      query['uid'] = { '$in' => permitted_query_uids }
    end

    query
  end

  def serialized_checkins(checkins)
    return checkins if privileged_access?
    checkins.map { |checkin| redact_uid(checkin) }
  end

  def redact_uid(record)
    attributes = record.respond_to?(:attributes) ? record.attributes : record
    attributes = attributes.as_json if attributes.respond_to?(:as_json)
    attributes = attributes.to_h if attributes.respond_to?(:to_h)
    attributes = attributes.dup
    uid_key = attributes.key?('uid') ? 'uid' : :uid
    attributes[uid_key] = redacted_uid_digest(attributes[uid_key]) if attributes.key?(uid_key)
    attributes
  end

  # Deterministic, keyed digest — stable across requests, workers, and
  # restarts (unlike String#hash, which uses a per-process random seed and
  # would render the same UID as a different value every time, breaking
  # any correlation of a member's own checkins over time or with the
  # matching rejections endpoint). Truncated to 12 hex chars: short enough
  # to be a clean display value, long enough that collisions among the
  # small set of real card UIDs in use are not a practical concern.
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

  # The frontend sends camelCase startTime/endTime, but the app-wide
  # ActionController::ParamsNormalizer (config/initializers/wrap_parameters.rb)
  # underscores every incoming param key before any controller code runs, so
  # by the time we get here they're already start_time/end_time. Reading the
  # camelCase keys here always returned nil, silently disabling the time
  # filter entirely (see #206 for the production incident this caused).
  def query_start_time
    return nil if params[:start_time].blank?
    params[:start_time].to_i
  end

  def query_end_time
    return nil if params[:end_time].blank?
    params[:end_time].to_i
  end
end
