class Volunteer::LeaderboardController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_member! rescue nil
  skip_after_action  :send_messages

  before_action :check_token

  # GET /volunteer/leaderboard
  # GET /volunteer/leaderboard.json
  def index
    top_count = (SystemConfig.get('volunteer_leaderboard_top') || 10).to_i

    # Fetch more than needed to account for deleted members,
    # then filter and re-rank after resolving member records.
    fetch_count = top_count * 3

    pipeline = [
      { '$match' => { 'status' => { '$in' => ['approved', 'reversal'] } } },
      { '$group' => { '_id' => '$member_id', 'lifetime_credits' => { '$sum' => '$credit_value' } } },
      { '$sort'  => { 'lifetime_credits' => -1 } },
      { '$limit' => fetch_count }
    ]

    rows = VolunteerCredit.collection.aggregate(pipeline).to_a

    member_ids    = rows.map { |r| r['_id'] }
    members_by_id = Member.in(id: member_ids).index_by(&:id)

    # Filter out deleted members, re-rank sequentially from 1
    @entries = rows.filter_map.with_index(1) do |row, idx|
      member = members_by_id[row['_id']]
      next if member.nil?
      {
        rank:             idx,
        name:             member.fullname,
        lifetime_credits: row['lifetime_credits'].to_f.round(1)
      }
    end.first(top_count).each.with_index(1) { |e, i| e[:rank] = i }

    if request.format.json?
      render plain: @entries.to_json, content_type: 'application/json'
    else
      render 'volunteer/leaderboard/index', layout: false
    end
  end

  private

  def check_token
    token_enabled = (SystemConfig.get('volunteer_bounty_token_enabled') ||
                     ENV.fetch('VOLUNTEER_BOUNTY_TOKEN_ENABLED', 'false')) == 'true'
    return unless token_enabled

    expected_token = SystemConfig.get('volunteer_bounty_token') ||
                     ENV.fetch('VOLUNTEER_BOUNTY_TOKEN', '')
    provided_token = params[:token].to_s

    unless expected_token.present? && ActiveSupport::SecurityUtils.secure_compare(provided_token, expected_token)
      if request.format.json?
        render plain: { error: 'Access denied.' }.to_json, content_type: 'application/json', status: :forbidden
      else
        render plain: 'Access denied.', status: :forbidden
      end
    end
  end
end
