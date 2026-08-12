# Redis 5.x removed Redis.current. Use this REDIS constant throughout the app.
# ssl_params skips certificate verification for Heroku Redis, which uses a
# self-signed cert on the rediss:// (SSL) connection.
base_redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')

redis_url = if ENV['TEST_ENV_NUMBER'].present?
  uri = URI.parse(base_redis_url)
  uri.path = "/#{ENV['TEST_ENV_NUMBER'].to_i}"
  uri.to_s
else
  base_redis_url
end

REDIS = Redis.new(
  url: redis_url,
  ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
)
