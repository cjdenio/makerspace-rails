require Rails.root.join('lib/mobile_session_client')
require 'devise/strategies/rememberable'
require 'devise/controllers/rememberable'

# Both paths need the same gate: Warden can restore cookies before controller
# callbacks (including route authentication), and timeoutable uses the helper
# even when the ordinary session already exists.
module MobileRememberableStrategy
  def valid?
    MobileSessionClient.phone?(request.user_agent) && super
  end
end

module MobileRememberableCookies
  def remember_me_is_active?(resource)
    MobileSessionClient.phone?(request.user_agent) && super
  end

  def remember_me(resource)
    super if MobileSessionClient.phone?(request.user_agent)
  end
end

Devise::Strategies::Rememberable.prepend(MobileRememberableStrategy)
Devise::Controllers::Rememberable.prepend(MobileRememberableCookies)

Warden::Manager.before_logout do |_record, warden, _options|
  warden.request.session.delete(:mobile_remember_pending)
end
