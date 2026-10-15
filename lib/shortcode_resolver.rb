# Runs before request parsing; dispatch remains in the ordinary Rails router.
class ShortcodeResolver
  def initialize(app)
    @app = app
  end

  def call(env)
    path = env["PATH_INFO"].to_s
    return @app.call(env) unless (path.start_with?("/L") || path.match?(%r{\A/l[2-9A-Za-z]{10}\z}))
    return failure(404, "Not Found", env) unless %w[GET HEAD].include?(env["REQUEST_METHOD"])
    code = path.delete_prefix("/L")
    return failure(404, "Not Found", env) unless ShortUrl::CODE.match?(code)
    origin = ShortUrl.base_url(fallback_host: Rack::Request.new(env).host_with_port)
    target = ShortUrl.resolve(code, origin: origin)
    return failure(404, "Not Found", env) unless target

    resolved = URI.parse(target).path
    forwarded = env.merge("PATH_INFO" => resolved, "QUERY_STRING" => "",
      "REQUEST_URI" => resolved, "shortcode.resolved_path" => resolved)
    status, headers, body = @app.call(forwarded)
    unless resolved.end_with?("/public.html")
      headers = headers.merge("cache-control" => "private, no-store")
    end
    [status, headers, body]
  rescue ShortUrl::Unavailable
    failure(503, "Service Unavailable", env)
  end

  private

  def failure(status, message, env)
    [status, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, env["REQUEST_METHOD"] == "HEAD" ? [] : [message]]
  end
end
