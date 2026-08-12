desc 'Find active members whose Braintree payment cards expire this month and notify them'
task card_on_file_expiration_check: :environment do
  Service::CardExpirationCheck.run!
end
