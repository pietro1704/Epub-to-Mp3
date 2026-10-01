require "json"
require "net/http"
require "uri"
class RustClient
  def initialize(base_url: ENV.fetch("RUST_CONVERTER_URL", "http://127.0.0.1:8000")); @base_uri = URI(base_url); end
  def health = request(:get, "/health")
  def metadata = request(:get, "/api/metadata")
  def convert(input:, engine: nil, voice: nil, language: nil)
    payload = { input: input }.compact
    payload[:engine] = engine if engine
    payload[:voice] = voice if voice
    payload[:language] = language if language
    request(:post, "/api/convert", payload)
  end
  def job(id) = request(:get, "/api/jobs/#{URI.encode_uri_component(id)}")
  private
  def request(method, path, payload=nil)
    uri = @base_uri + path
    klass = method == :get ? Net::HTTP::Get : Net::HTTP::Post
    req = klass.new(uri); req["Accept"] = "application/json"
    if payload; req["Content-Type"] = "application/json"; req.body = JSON.generate(payload); end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    body = response.body.to_s; parsed = body.empty? ? {} : JSON.parse(body)
    return parsed if response.is_a?(Net::HTTPSuccess)
    raise "Rust converter returned #{response.code}: #{body}"
  end
end
