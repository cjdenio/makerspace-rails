# Faraday 2.x removed the implicit default adapter.
# Explicitly set :net_http so all Faraday connections work
# without requiring an additional adapter gem.
Faraday.default_adapter = :net_http
