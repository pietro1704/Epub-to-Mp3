require "json"
require "net/http"
require "uri"

class RustClient
  def initialize(base_url: ENV.fetch("RUST_CONVERTER_URL", "http://127.0.0.1:8000"))
    @base_uri = URI(base_url)
  end

  def health = request(:get, "/health")
  def metadata = request(:get, "/api/metadata")

  private

  def request(method, path, payload = nil)
    uri = @base_uri + path
    request_class = method == :get ? Net::HTTP::Get : Net::HTTP::Post
    request = request_class.new(uri)
    request["Accept"] = "application/json"
    if payload
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    body = response.body.to_s
    parsed = body.empty? ? {} : JSON.parse(body)
    return parsed if response.is_a?(Net::HTTPSuccess)
    raise "Rust converter returned #{response.code}: #{body}"
  end
end
