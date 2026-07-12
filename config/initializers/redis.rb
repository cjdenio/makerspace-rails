# Redis 5.x removed Redis.current. Use this REDIS constant throughout the app.
# ssl_params skips certificate verification for Heroku Redis, which uses a
# self-signed cert on the rediss:// (SSL) connection.
REDIS = Redis.new(
  url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
  ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
)
