# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "digest"
require "timeout"
require "time"

class GradioEventReader
  def initialize(&consumer)
    @buffer = +"".b
    @consumer = consumer
  end

  def feed(chunk)
    @buffer << chunk.b
    @buffer.gsub!("\r\n", "\n")
    while (boundary = @buffer.index("\n\n"))
      block = @buffer.slice!(0, boundary + 2).force_encoding(Encoding::UTF_8)
      event = block.lines.find { |line| line.start_with?("event:") }&.delete_prefix("event:")&.strip
      data = block.lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }.join("\n")
      @consumer.call(event, data.empty? ? nil : JSON.parse(data)) if event
    end
  end
end

module GradioProbe
  class ProviderError < StandardError; end
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.request(uri, request, report)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      http.max_retries = 0
      http.request(request) do |response|
        report["http_status"] = response.code.to_i
        report["response_headers"] = response.to_hash.select { |key, _| key.match?(/\A(?:retry-after|ratelimit(?:-policy)?|content-type)\z/i) }
        unless response.is_a?(Net::HTTPSuccess)
          report["status"] = [401, 403, 429].include?(response.code.to_i) ? "provider_limit_or_refusal" : "http_error"
          raise ProviderError, "HTTP #{response.code}; no retries performed"
        end
        yield response
      end
    end
  end

  def self.run(spec_path:, text_file:, output:, timeout: 120)
    spec = JSON.parse(File.read(spec_path))
    base = URI(spec.fetch("base_url"))
    raise ArgumentError, "Use a reviewed public Space deployment" unless base.scheme == "https" && base.host.end_with?(".hf.space") && !base.userinfo && !base.query
    api = spec.fetch("api_name")
    raise ArgumentError, "Use a public named API" unless api.match?(/\A[a-zA-Z0-9_-]+\z/)
    text = File.read(text_file, encoding: "UTF-8")
    raise ArgumentError, "Text exceeds reviewed demo limit" unless (1..spec.fetch("max_chars")).cover?(text.length)
    raise ArgumentError, "Never overwrite previous results" if [output, output + ".partial", output + ".timing.json"].any? { |p| File.exist?(p) }
    start = clock
    report = { "provider" => spec.fetch("provider"), "voice" => spec.fetch("voice"), "base_url" => base.to_s,
               "api_name" => api, "model_revision" => spec.fetch("model_revision", "not exposed"),
               "spec_sha256" => Digest::SHA256.file(spec_path).hexdigest, "text_sha256" => Digest::SHA256.hexdigest(text),
               "probe_sha256" => Digest::SHA256.file(__FILE__).hexdigest, "request_start_monotonic_s" => start,
               "server_cache" => "unknown", "authentication" => "anonymous; no token, cookie or account used",
               "streaming" => false, "first_pcm_request_s" => nil, "status" => "started", "events" => [] }
    code = 0
    begin
      Timeout.timeout(timeout) do
        uri = URI.join(base.to_s, "/gradio_api/call/#{api}")
        post = Net::HTTP::Post.new(uri)
        post["Content-Type"] = "application/json"
        post.body = JSON.generate("data" => spec.fetch("arguments").map { |v| v == "{text}" ? text : v })
        response_body = +""
        request(uri, post, report) { |response| response.read_body { |chunk| response_body << chunk } }
        event_id = JSON.parse(response_body).fetch("event_id")
        raise "Invalid event identity" unless event_id.is_a?(String) && event_id.match?(/\A[a-zA-Z0-9_-]+\z/)
        report["queue_accepted_s"] = clock - start
        completed = nil
        reader = GradioEventReader.new do |event, payload|
          report.fetch("events") << { "event" => event, "elapsed_s" => clock - start }
          if event == "error"
            message = payload.to_s
            report["status"] = "provider_limit_or_refusal" if message.match?(/quota|rate.?limit|too many|sign.?in|log.?in|zerogpu|exceeded/i)
            raise ProviderError, message[0, 800]
          elsif event == "complete"
            completed = payload
            report["complete_server_audio_ready_s"] = clock - start
          end
        end
        stream_uri = URI(uri.to_s + "/" + event_id)
        request(stream_uri, Net::HTTP::Get.new(stream_uri), report) { |response| response.read_body { |chunk| reader.feed(chunk) } }
        raise ProviderError, "Queue closed without a completed result" unless completed.is_a?(Array)
        file = completed[spec.fetch("audio_output_index", 0)]
        unless file.is_a?(Hash) && file["url"]
          message = completed.to_s
          report["status"] = "provider_limit_or_refusal" if message.match?(/quota|rate.?limit|sign.?in|log.?in|zerogpu|exceeded/i)
          raise ProviderError, "No audio returned: #{message[0, 800]}"
        end
        download = URI.join(base.to_s, file.fetch("url"))
        allowed = download.scheme == "https" && (download.host == base.host || download.host.end_with?(".hf.space", ".huggingface.co", ".xethub.hf.co")) && !download.userinfo
        raise ProviderError, "Unreviewed audio host or URL" unless allowed
        report["file_host"] = download.host
        File.open(output + ".partial", "wb", 0o600) do |audio|
          request(download, Net::HTTP::Get.new(download), report) do |response|
            response.read_body do |chunk|
              report["first_file_byte_s"] ||= clock - start
              audio.write(chunk)
              report["last_file_byte_s"] = clock - start
            end
          end
          audio.flush
          audio.fsync
        end
        File.rename(output + ".partial", output)
        report["complete_audio_file_persisted_s"] = clock - start
        report["audio_sha256"] = Digest::SHA256.file(output).hexdigest
        report["bytes"] = File.size(output)
        report["status"] = "received_file_needs_decode_validation"
      end
    rescue Interrupt
      report["status"] = "cancelled"
      code = 130
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      report.merge!("status" => "timeout", "error" => "#{error.class}: #{error.message}")
      code = 124
    rescue StandardError => error
      report["status"] = "failed" if report["status"] == "started"
      report["error"] = "#{error.class}: #{error.message}"
      code = 1
    ensure
      report["client_total_s"] = clock - start
      File.write(output + ".timing.json.partial", JSON.pretty_generate(report) + "\n")
      File.rename(output + ".timing.json.partial", output + ".timing.json")
    end
    puts JSON.generate(report)
    code
  end

  def self.cli(arguments)
    options = { timeout: 120.0 }
    OptionParser.new do |parser|
      parser.on("--spec FILE") { |v| options[:spec_path] = File.expand_path(v) }
      parser.on("--text-file FILE") { |v| options[:text_file] = File.expand_path(v) }
      parser.on("--output FILE") { |v| options[:output] = File.expand_path(v) }
      parser.on("--timeout SECONDS", Float) { |v| options[:timeout] = v }
    end.parse!(arguments)
    raise ArgumentError, "Required: --spec --text-file --output" unless arguments.empty? && %i[spec_path text_file output].all? { |key| options[key] }
    run(**options)
  rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError => error
    warn error.message
    2
  end
end

exit GradioProbe.cli(ARGV) if $PROGRAM_NAME == __FILE__
