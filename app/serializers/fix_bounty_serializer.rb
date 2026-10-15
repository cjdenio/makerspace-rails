class FixBountySerializer < VolunteerTaskSerializer
  attribute :capabilities do
    {
      canClaim: !!(scope&.fully_active_unexpired? && object.status == 'available' && object.eligible_for?(scope)),
      canSubmitCompletion: !!(scope && object.status == 'claimed' && object.claimed_by_id == scope.id)
    }
  end
end
