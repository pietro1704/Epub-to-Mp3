# frozen_string_literal: true

require "net/http"
require "json"
require "digest"
require "optparse"
require "securerandom"
require "time"
require "timeout"

# Inspect actual PCM arrivals, rather than treating a WAV header as speech.
class PocketWaveArrival
  attr_reader :format, :first_pcm, :first_signal, :pcm_bytes, :declared_data_bytes

  def initialize(streaming_size_sentinels: [], &write_pcm)
    @header = +"".b
    @pending = +"".b
    @format = nil
    @remaining = nil
    @pcm_bytes = 0
    @write_pcm = write_pcm
    @streaming_size_sentinels = streaming_size_sentinels
  end

  def feed(bytes, timestamp)
    unless @remaining
      @header << bytes.b
      raise "Invalid RIFF/WAVE response" if @header.bytesize >= 12 && (@header[0, 4] != "RIFF" || @header[8, 4] != "WAVE")
      return if @header.bytesize < 12
      offset = 12
      loop do
        return if @header.bytesize < offset + 8
        kind = @header[offset, 4]
        size = @header[offset + 4, 4].unpack1("V")
        if kind == "data"
          raise "Missing supported PCM format" unless @format
          @declared_data_bytes = size
          @remaining = size >= 0x7fffffff || @streaming_size_sentinels.include?(size) ? Float::INFINITY : size
          bytes = @header.byteslice(offset + 8..).to_s.b
          @header = +"".b
          break
        end
        raise "Unbounded WAV metadata chunk" if size > 65_536
        return if @header.bytesize < offset + 8 + size
        if kind == "fmt "
          codec, channels, rate, _, align, bits = @header[offset + 8, 16].unpack("vvVVvv")
          raise "Only PCM16 WAV is supported" unless codec == 1 && bits == 16 && channels.positive? && align == channels * 2 && rate.positive?
          @format = { "channels" => channels, "sample_rate" => rate, "bits" => bits, "block_align" => align }
        end
        offset += 8 + size + size % 2
      end
    end
    portion = @remaining.infinite? ? bytes : bytes.byteslice(0, @remaining)
    @remaining -= portion.bytesize unless @remaining.infinite?
    @pending << portion.b
    length = @pending.bytesize / @format.fetch("block_align") * @format.fetch("block_align")
    return if length.zero?
    pcm = @pending.slice!(0, length)
    @first_pcm ||= timestamp
    @first_signal ||= timestamp if pcm.unpack("s<*").any? { |sample| sample.abs > 32 }
    @pcm_bytes += pcm.bytesize
    @write_pcm.call(pcm)
  end

  def finish
    raise "No non-silent PCM received" unless @format && @first_signal && @pcm_bytes.positive?
    raise "Incomplete PCM frame" unless @pending.empty?
    raise "Truncated declared WAV data" unless @remaining.infinite? || @remaining.zero?
  end
end

module PocketHttpProbe
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.run(url:, voice:, text_file:, output:, timeout: 90)
    text = File.read(text_file, encoding: "UTF-8")
    raise ArgumentError, "Pocket demo accepts 1..500 characters" unless (1..500).cover?(text.length)
    uri = URI(url)
    raise ArgumentError, "Use the documented official HTTPS endpoint" unless uri.scheme == "https" && uri.host == "pocket-tts-api.kyutai.org" && %w[/portuguese/tts /english/tts].include?(uri.path) && !uri.query && !uri.userinfo
    raise ArgumentError, "Use the reviewed built-in voice" unless %w[rafael alba].include?(voice)
    raise ArgumentError, "Invalid timeout" unless timeout.positive? && timeout.finite?
    metadata_path = output + ".timing.json"
    raw_path = output + ".response.wav"
    pcm_path = output + ".pcm.partial"
    raise ArgumentError, "Never overwrite a previous request" if [output, metadata_path, raw_path, pcm_path, output + ".partial"].any? { |path| File.exist?(path) }
    report = { "provider" => "Pocket official remote demo", "url" => url, "voice" => voice,
               "model_revision" => "not exposed", "server_cache" => "unknown", "connection" => "fresh",
               "text_sha256" => Digest::SHA256.hexdigest(text), "characters" => text.length,
               "started_utc" => Time.now.utc.iso8601, "probe_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
               "first_signal_threshold" => "absolute signed PCM16 sample >32 (approximately -60 dBFS), not speaker output",
               "status" => "started", "request_start_monotonic_s" => clock }
    start = report.fetch("request_start_monotonic_s")
    boundary = "tts-benchmark-#{SecureRandom.hex(12)}"
    body = { "text" => text, "voice_url" => voice }.map do |name, value|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end.join + "--#{boundary}--\r\n"
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request["User-Agent"] = "epubtomp3-tts-benchmark/1"
    request.body = body
    code = 0
    wave = nil
    begin
      File.open(raw_path, "wb", 0o600) do |raw|
        File.open(pcm_path, "wb", 0o600) do |pcm|
          # The observed first-party streaming endpoint announces 2 GB of data;
          # its official web client consumes PCM to EOF and rebuilds the header.
          # Accept this explicit protocol sentinel, never arbitrary truncation.
          wave = PocketWaveArrival.new(streaming_size_sentinels: [2_000_000_000]) { |bytes| pcm.write(bytes) }
          Timeout.timeout(timeout) do
            Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30, write_timeout: 15) do |http|
              http.max_retries = 0
              http.request(request) do |response|
                report["http_status"] = response.code.to_i
                report["headers_s"] = clock - start
                report["response_headers"] = response.to_hash.select { |key, _| key.match?(/\A(?:content-type|retry-after|ratelimit(?:-policy)?|x-ratelimit-[a-z-]+|x-request-id)\z/i) }
                unless response.is_a?(Net::HTTPSuccess)
                  report["status"] = [403, 429].include?(response.code.to_i) ? "provider_limit_or_refusal" : "http_error"
                  report["error"] = "HTTP #{response.code}; no retries performed"
                  code = 1
                  break
                end
                response.read_body do |chunk|
                  arrived = clock - start
                  report["first_body_s"] ||= arrived
                  raw.write(chunk)
                  wave.feed(chunk, arrived)
                  report["last_body_s"] = arrived
                end
              end
            end
          end
          if code.zero?
            wave.finish
            pcm.flush
            pcm.fsync
            report.merge!(wave.format)
            report["first_pcm_request_s"] = wave.first_pcm
            report["first_non_silent_pcm_request_s"] = wave.first_signal
            report["pcm_bytes"] = wave.pcm_bytes
            report["audio_duration_s"] = wave.pcm_bytes.fdiv(wave.format.fetch("sample_rate") * wave.format.fetch("block_align"))
          end
        end
        raw.flush
        raw.fsync
      end
      if code.zero?
        channels, rate, bits, size = report.values_at("channels", "sample_rate", "bits", "pcm_bytes")
        header = "RIFF".b + [size + 36].pack("V") + "WAVEfmt " + [16, 1, channels, rate, rate * channels * 2, channels * 2, bits].pack("VvvVVvv") + "data" + [size].pack("V")
        File.open(output + ".partial", "wb", 0o600) do |file|
          file.write(header)
          IO.copy_stream(pcm_path, file)
          file.flush
          file.fsync
        end
        File.rename(output + ".partial", output)
        report["complete_wav_persisted_s"] = clock - start
        report["wav_sha256"] = Digest::SHA256.file(output).hexdigest
        report["raw_response_sha256"] = Digest::SHA256.file(raw_path).hexdigest
        report["status"] = "received_non_silent_pcm"
        File.unlink(pcm_path)
      end
    rescue Interrupt
      report["status"] = "cancelled"
      code = 130
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      report.merge!("status" => "timeout", "error" => error.message)
      code = 124
    rescue StandardError => error
      report.merge!("status" => "failed", "error" => "#{error.class}: #{error.message}")
      code = 1
    ensure
      if wave&.format
        report.merge!(wave.format)
        report["first_pcm_request_s"] = wave.first_pcm
        report["first_non_silent_pcm_request_s"] = wave.first_signal
        report["pcm_bytes"] = wave.pcm_bytes
        report["declared_wav_data_bytes"] = wave.declared_data_bytes
      end
      report["client_total_s"] = clock - start
      File.write(metadata_path + ".partial", JSON.pretty_generate(report) + "\n")
      File.rename(metadata_path + ".partial", metadata_path)
    end
    puts JSON.generate(report)
    code
  end

  def self.cli(arguments)
    options = { timeout: 90.0 }
    OptionParser.new do |parser|
      parser.on("--url URL") { |v| options[:url] = v }
      parser.on("--voice NAME") { |v| options[:voice] = v }
      parser.on("--text-file FILE") { |v| options[:text_file] = File.expand_path(v) }
      parser.on("--output FILE") { |v| options[:output] = File.expand_path(v) }
      parser.on("--timeout SECONDS", Float) { |v| options[:timeout] = v }
    end.parse!(arguments)
    raise ArgumentError, "Required: --url --voice --text-file --output" unless arguments.empty? && %i[url voice text_file output].all? { |key| options[key] }
    run(**options)
  rescue ArgumentError, SystemCallError => error
    warn error.message
    2
  end
end

exit PocketHttpProbe.cli(ARGV) if $PROGRAM_NAME == __FILE__
