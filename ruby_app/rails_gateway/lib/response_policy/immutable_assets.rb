module ResponsePolicy
  # Digested Propshaft output never changes under a given name. Other public
  # files keep the revalidating default from public_file_server.headers.
  class ImmutableAssets
    IMMUTABLE = "public, max-age=31536000, immutable".freeze

    def initialize(app, prefix: "/assets/")
      @app = app
      @prefix = prefix
    end

    def call(env)
      status, headers, body = @app.call(env)
      headers["cache-control"] = IMMUTABLE if env["PATH_INFO"].to_s.start_with?(@prefix) && [ 200, 206, 304 ].include?(status)
      [ status, headers, body ]
    end
  end
end
