class RentalVacatingCheckJob < ApplicationJob
  queue_as :default

  # Run nightly — checks for vacating rentals that have passed their expiration
  # Schedule this in your cron/scheduler (e.g. whenever gem or Heroku Scheduler)
  # Example: every 1.day, at: '2:00 am' -> RentalVacatingCheckJob.perform_later
  def perform
    now_ms = Time.now.to_i * 1000

    expired_vacating = Rental.where(
      status: "vacating",
      :expiration.lte => now_ms
    )

    expired_vacating.each do |rental|
      begin
        rental.update_attributes!(status: "cancelled")

        member = rental.member
        next if member.nil?

        # Slack DM to member
        slack_user = SlackUser.find_by(member_id: member.id)
        unless slack_user.nil?
          ::Service::SlackConnector.send_slack_message(
            "Your rental of *#{rental.number}* has now ended. Thank you — the space is available for other members.",
            slack_user.slack_id
          )
        end

        # Admin channel notification
        ::Service::SlackConnector.send_slack_message(
          "🔴 #{member.fullname}'s rental of *#{rental.number}* has expired and been automatically cancelled."
        )

        RentalMailer.rental_ended(member.id.to_s, rental.id.to_s).deliver_later

        Rails.logger.info("Auto-cancelled vacating rental #{rental.id} (#{rental.number}) for #{member.fullname}")
      rescue => err
        Rails.logger.error("Error auto-cancelling vacating rental #{rental.id}: #{err}")
      end
    end
  end
end
