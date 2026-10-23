module VolunteerCreditMessaging
  TIMING_NOTICE = "Volunteer credits are applied in the month following the activity date. For example, a task completed in April is reflected in your May credit totals.".freeze
  REVIEW_NOTICE = "Please wait for a volunteer approver to review your activity. Our approvers are unpaid volunteers and will review it when they can. Thank you for your patience.".freeze
  CLAIM_NOTICE = "#{TIMING_NOTICE}\n\n#{REVIEW_NOTICE}".freeze
end
