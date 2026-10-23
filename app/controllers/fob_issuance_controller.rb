# Lets volunteers who hold the fob-issuer checkout (see Member#fob_issuer?) register a
# member's FIRST key fob. Separate from Admin::CardsController on purpose: that
# controller stays admin/board only, and everything here is narrower -- initial
# issue only, never to oneself, never to a revoked member, identity fields only.
class FobIssuanceController < AuthenticationController
  before_action :require_fob_issuer!
  before_action { response.set_header('Cache-Control', 'private, no-store') }
  rescue_from CardManagement::Conflict do |error|
    render json: { error: error.message }, status: :conflict
  end
  rescue_from CardManagement::Unavailable do |error|
    render json: { error: error.message }, status: :service_unavailable
  end

  MAX_RESULTS = 25

  def members
    term = params[:search].to_s.strip
    return render json: [], adapter: :attributes if term.length < 2

    pattern = /#{Regexp.escape(term)}/i
    found = eligible_members.any_of(
      { firstname: pattern }, { lastname: pattern }, { email: pattern }
    ).limit(MAX_RESULTS)
    render json: found.to_a, each_serializer: FobIssuanceMemberSerializer, adapter: :attributes
  end

  def show
    member = eligible_members.where(id: params[:id]).first
    raise Error::NotFound.new unless member
    render json: member, serializer: FobIssuanceMemberSerializer, adapter: :attributes
  end

  def new_card
    reject = CardManagement.importable_rejections.sort(timeOf: 1).last
    render json: { uid: reject&.uid }
  end

  def create
    params.require([:member_id, :uid])
    member = eligible_members.where(id: params[:member_id]).first
    raise Error::NotFound.new unless member
    uid = params[:uid]
    unless uid.is_a?(String) && (uid.match?(/\A(?:[0-9A-F]{2})+\z/) ||
        CardManagement.importable_rejections.where(uid: uid).exists?)
      return render json: { error: 'UID must be uppercase hexadecimal ASCII byte pairs or match a recent unclaimed reader rejection.' },
        status: :unprocessable_entity
    end

    card = CardManagement.assign!({ member_id: member.id.to_s, uid: uid }, current_member,
      uid_source: params[:source], initial_only: true)
    FobIssuanceNotifier.notify(member, current_member)
    render json: card, adapter: :attributes
  end

  private

  def require_fob_issuer!
    raise Error::Forbidden.new unless current_member.fob_issuer?
  end

  # Members who may receive a first fob from a volunteer: someone else, not revoked,
  # with no usable card yet.
  def eligible_members
    holders = Card.where(:validity.nin => %w[lost stolen]).distinct(:member_id)
    Member.where(:id.nin => holders + [current_member.id], :status.ne => 'revoked')
  end
end
