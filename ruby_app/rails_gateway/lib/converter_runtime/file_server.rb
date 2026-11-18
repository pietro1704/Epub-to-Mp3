require "rack/files"
require_relative "tree"

module ConverterRuntime
  # Serves the current runtime tree at /runtime/<id>/ with explicit media types
  # and immutable caching. Generated glue and Emscripten locate siblings by
  # relative URL, so file names are never digested; the id versions the path.
  class FileServer
    IMMUTABLE = "public, max-age=31536000, immutable".freeze
    MEDIA_TYPES = {
      ".js" => "text/javascript",
      ".mjs" => "text/javascript",
      ".wasm" => "application/wasm",
      ".json" => "application/json",
      ".data" => "application/octet-stream"
    }.freeze
    DEFAULT_MEDIA_TYPE = "application/octet-stream".freeze
    PREFIX = "#{Tree::MOUNT_PATH}/".freeze

    def initialize(app, tree)
      @app = app
      @tree = tree
    end

    def call(env)
      path = env["PATH_INFO"].to_s
      return @app.call(env) unless path.start_with?(PREFIX)

      runtime_id, relative_path = path.delete_prefix(PREFIX).split("/", 2)
      return not_found unless %w[GET HEAD].include?(env["REQUEST_METHOD"])
      return not_found unless runtime_id == @tree.id && @tree.file?(relative_path.to_s)

      serve(env, relative_path)
    end

    private

    def serve(env, relative_path)
      status, headers, body = Rack::Files.new(@tree.directory.to_s).call(env.merge("PATH_INFO" => "/#{relative_path}"))
      if [ 200, 206, 304 ].include?(status)
        headers["content-type"] = MEDIA_TYPES.fetch(File.extname(relative_path), DEFAULT_MEDIA_TYPE) unless status == 304
        headers["cache-control"] = IMMUTABLE
        headers["x-content-type-options"] = "nosniff"
      end
      [ status, headers, body ]
    end

    def not_found
      [ 404, { "content-type" => "text/plain", "cache-control" => "no-store" }, [ "Not Found" ] ]
    end
  end
end
