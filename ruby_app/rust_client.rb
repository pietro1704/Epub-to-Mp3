# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module EpubToMp3
  class RustClient
    def initialize(base_url: ENV.fetch("RUST_CONVERTER_URL", "http://127.0.0.1:8787"))
      @base_uri = URI(base_url)
    end

    def health
      request(:get, "/health")
    end

    def metadata
      request(:get, "/api/metadata")
    end

    def create_conversion(upload_id:, engine: nil, language: nil, voice: nil)
      payload = { upload_id: upload_id, engine: engine, language: language, voice: voice }.compact
      request(:post, "/api/convert", payload)
    end

    private

    def request(method, path, payload = nil)
      uri = @base_uri + path
      klass = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      req = klass.new(uri)
      req["Accept"] = "application/json"
      if payload
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
      body = response.body.to_s
      parsed = body.empty? ? {} : JSON.parse(body)
      return parsed if response.is_a?(Net::HTTPSuccess)
      raise "Rust converter returned #{response.code}: #{body}"
    rescue JSON::ParserError => e
      raise "Rust converter returned invalid JSON: #{e.message}"
    end
  end
end
