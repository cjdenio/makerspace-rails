class SlackGroupApprovalModal
  def self.verifier
    Rails.application.message_verifier('slack_group_checkout')
  end

  def self.build(actor:, member:, group:, slack_user_id:)
    raise Error::Forbidden.new unless ToolGroupCheckout.authorized?(actor, group)
    review = ToolGroupCheckout.review(member: member, group: group)
    ToolGroupCheckout.validate_review!(review)
    names = ->(ids) { Tool.where(:id.in => ids).order_by(name: :asc).map(&:name).join(', ').presence || 'None' }
    lines = [":linked_paperclips: #{group.name} — #{member.fullname}",
      "Included: #{names.call(review[:included_tool_ids])}", "Already held: #{names.call(review[:held_tool_ids])}",
      "New checkouts: #{names.call(review[:create_tool_ids])}", "External prerequisites: #{names.call(review[:prerequisite_ids])}"]
    { type: 'modal', callback_id: 'group_checkout_approve',
      private_metadata: verifier.generate({ actor_id: actor.id.to_s, member_id: member.id.to_s,
        group_id: group.id.to_s, revision: group.revision, slack_user_id: slack_user_id }, purpose: 'approval', expires_in: 1.hour),
      title: { type: 'plain_text', text: 'Approve group checkout' },
      submit: { type: 'plain_text', text: 'Approve' }, close: { type: 'plain_text', text: 'Cancel' },
      blocks: lines.map { |line| { type: 'section', text: { type: 'plain_text', text: line.first(2900), emoji: true } } } }
  end

  def self.submit!(payload)
    metadata = verifier.verified(payload.dig('view', 'private_metadata'), purpose: 'approval')
    raise Error::Forbidden.new('This review has expired') unless metadata.is_a?(Hash)
    metadata = metadata.symbolize_keys
    identity_check = -> {
      link = SlackUser.find_by(slack_id: payload.dig('user', 'id'))
      unless link && payload.dig('user', 'id') == metadata[:slack_user_id] && link.member_id.to_s == metadata[:actor_id]
        raise Error::Forbidden.new('Your linked account changed')
      end
    }
    identity_check.call
    ToolGroupCheckout.approve!(actor: Member.find(metadata[:actor_id]), member: Member.find(metadata[:member_id]),
      group: ToolGroup.find(metadata[:group_id]), revision: metadata[:revision], source: 'slack', &identity_check)
  end
end
