class BraintreeCustomerSyncJob < ApplicationJob
  include Service::BraintreeGateway

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id)
    member = Member.find(member_id)
    return unless member&.customer_id

    # https://developers.braintreepayments.com/reference/request/customer/update/ruby
    connect_gateway.customer.update(
      member.customer_id,
      first_name: member.firstname,
      last_name: member.lastname,
      email: member.email
    )
  rescue Mongoid::Errors::DocumentNotFound
    nil
  rescue => error
    ::Service::SlackConnector.send_slack_message(
      "Failed to sync Braintree customer info for #{member&.fullname} (#{member_id}) after retries: #{error.class}: #{error.message}",
      ::Service::SlackConnector.logs_channel
    )
    Service::ErrorReporter.notify(error)
    raise
  end
end
