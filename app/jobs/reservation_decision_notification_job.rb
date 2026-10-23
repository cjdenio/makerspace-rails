# Retain this entry point for decision jobs already queued before deployment.
# Both decisions and fee changes update the reservation's saved DM.
class ReservationDecisionNotificationJob < ReservationFeeNotificationJob
end
