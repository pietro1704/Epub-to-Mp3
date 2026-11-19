# frozen_string_literal: true

# Derive timings from an explicitly selected, local Apple diagnostic export.
#
# Artifact hashes establish byte identity, not authenticity or proof of relaunch.
# Those properties belong to the collection harness and its execution evidence.

require "digest"
require "json"

module AppleLatencyEvidence
  # Malformed or unsupported Apple evidence; messages never echo content or paths.
  class Error < StandardError; end

  # Raised by decode_json for any document that is not strict, unique-key JSON.
  class InvalidJson < StandardError; end
  class DuplicateKey < InvalidJson; end

  DOCUMENT_KINDS = {
    "epub" => "epub",
    "selectable_text_pdf" => "selectable_text_pdf",
    "sideways_two_up_scanned_pdf" => "normalized_scanned_pdf"
  }.freeze
  KINDS = {
    "book_open" => %w[open_requested readable_content controls_usable first_pdf_page cancelled].freeze,
    "progressive_playback" => %w[play_requested audio_queued audio_audible cancelled].freeze,
    "seek" => %w[seek_requested seek_target_reached cancelled].freeze
  }.freeze
  CACHE_CLASSES = %w[unknown cold prepared_disk in_memory_warm].freeze
  STREAM_KINDS = %w[progressive_playback seek].freeze
  UINT64_MAX = (2**64) - 1
  UUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  BOMS = [
    ["\x00\x00\xFE\xFF".b, Encoding::UTF_32BE], ["\xFF\xFE\x00\x00".b, Encoding::UTF_32LE],
    ["\xFE\xFF".b, Encoding::UTF_16BE], ["\xFF\xFE".b, Encoding::UTF_16LE],
    ["\xEF\xBB\xBF".b, Encoding::UTF_8]
  ].freeze

  module_function

  # Mirrors Python json.loads(bytes): encoding detection, NaN/Infinity literals and,
  # like the object_pairs_hook used by the Python original, duplicate-key rejection.
  def decode_json(raw)
    JSON.parse(decode_text(raw), allow_nan: true, allow_duplicate_key: false, max_nesting: false)
  rescue JSON::ParserError => e
    raise DuplicateKey if e.message.start_with?("duplicate key")

    raise InvalidJson
  rescue SystemStackError, EncodingError
    raise InvalidJson
  end

  def decode_text(raw)
    bytes = raw.b
    encoding, skip = detect_encoding(bytes)
    text = bytes.byteslice(skip, bytes.bytesize).force_encoding(encoding)
    raise InvalidJson unless text.valid_encoding?

    text.encode(Encoding::UTF_8)
  end

  def detect_encoding(bytes)
    BOMS.each { |bom, encoding| return [encoding, bom.bytesize] if bytes.start_with?(bom) }
    b = bytes.bytes
    if b.length >= 4
      return [b[1].zero? ? Encoding::UTF_32BE : Encoding::UTF_16BE, 0] if b[0].zero?
      return [b[2].zero? && b[3].zero? ? Encoding::UTF_32LE : Encoding::UTF_16LE, 0] if b[1].zero?
    elsif b.length == 2
      return [Encoding::UTF_16BE, 0] if b[0].zero?
      return [Encoding::UTF_16LE, 0] if b[1].zero?
    end
    [Encoding::UTF_8, 0]
  end

  def object(value, fields)
    raise Error, "Invalid Apple diagnostic fields" unless value.is_a?(Hash) && value.keys.to_set == fields.to_set

    value
  end

  def uuid(value)
    raise Error, "Invalid Apple journey identifier" unless value.is_a?(String) && UUID_PATTERN.match?(value)

    value.downcase
  end

  def unsigned?(value, minimum = 0)
    value.is_a?(Integer) && value >= minimum && value <= UINT64_MAX
  end

  def validate_publication_id(identifier)
    raise Error, "Invalid Apple publication identifier" unless identifier.is_a?(String)

    numeric = /\A[0-9]{1,20}\z/.match?(identifier)
    hexadecimal = /\A\h{32}\z/.match?(identifier)
    uuid(identifier) unless numeric || hexadecimal
  end

  def validate_publication(value)
    publication = object(value, %w[publicationId producer])
    validate_publication_id(publication["publicationId"])
    producer = object(publication["producer"], %w[
      version attemptId segmentReadyElapsedNanoseconds artifactPublishedElapsedNanoseconds
    ])
    raise Error, "Unsupported Apple producer version" unless producer["version"].is_a?(Integer) && producer["version"] == 1

    uuid(producer["attemptId"])
    ready = producer["segmentReadyElapsedNanoseconds"]
    published = producer["artifactPublishedElapsedNanoseconds"]
    raise Error, "Invalid Apple producer timing" unless unsigned?(ready) && unsigned?(published, ready)
  end

  def validate_stream_request(journey, journey_id)
    receipt = object(journey["streamRequest"], %w[journeyId requestId publicationId])
    raise Error, "Apple stream request journey mismatch" if uuid(receipt["journeyId"]) != journey_id

    uuid(receipt["requestId"])
    validate_publication_id(receipt["publicationId"])
    return unless journey.key?("streamPublication")
    return if receipt["publicationId"] == journey["streamPublication"]["publicationId"]

    raise Error, "Apple stream request publication mismatch"
  end

  def validate_journey(value)
    fields = %w[id kind context records]
    fields += %w[streamPublication streamRequest].select { |key| value.key?(key) } if value.is_a?(Hash)
    journey = object(value, fields)
    journey_id = uuid(journey["id"])
    kind = journey["kind"]
    raise Error, "Unsupported Apple journey kind" unless kind.is_a?(String) && KINDS.key?(kind)

    if journey.key?("streamPublication")
      raise Error, "Apple publication is not allowed for this journey" unless STREAM_KINDS.include?(kind)

      validate_publication(journey["streamPublication"])
    end
    if journey.key?("streamRequest")
      raise Error, "Apple stream request is not allowed for this journey" unless STREAM_KINDS.include?(kind)

      validate_stream_request(journey, journey_id)
    end
    context = object(journey["context"], %w[documentKind cacheClass])
    raise Error, "Unsupported Apple document kind" unless DOCUMENT_KINDS.values.include?(context["documentKind"])
    raise Error, "Unsupported Apple cache class" unless CACHE_CLASSES.include?(context["cacheClass"])

    validate_records(journey["records"], kind)
    journey
  end

  def validate_records(records, kind)
    raise Error, "Missing Apple journey records" unless records.is_a?(Array) && !records.empty?

    previous = 0
    records.each do |value|
      record = object(value, %w[transition elapsedNanoseconds])
      transition = record["transition"]
      elapsed = record["elapsedNanoseconds"]
      raise Error, "Unsupported Apple journey transition" unless transition.is_a?(String) && KINDS[kind].include?(transition)
      raise Error, "Invalid Apple monotonic timing" unless unsigned?(elapsed, previous)

      previous = elapsed
    end
  end

  def timings(journey, initial, required)
    records = journey["records"]
    raise Error, "Missing Apple initial boundary" unless records[0] == { "transition" => initial, "elapsedNanoseconds" => 0 }

    first = {}
    records.each_with_index do |record, index|
      transition = record["transition"]
      if transition == "cancelled" || (index.positive? && transition == initial)
        raise Error, "Selected Apple journey is cancelled or invalid"
      end
      if transition == "audio_audible" && !first.key?("audio_queued")
        raise Error, "Apple audible boundary precedes queue readiness"
      end
      if %w[audio_queued audio_audible seek_target_reached].include?(transition) && first.key?(transition)
        raise Error, "Duplicate Apple playback boundary"
      end

      # Integer#fdiv divides exactly before rounding, like Python true division.
      first[transition] = record["elapsedNanoseconds"].fdiv(1_000_000) unless first.key?(transition)
    end
    raise Error, "Selected Apple journey is incomplete" unless required.all? { |boundary| first.key?(boundary) }

    required.to_h { |boundary| [boundary, first[boundary]] }
  end

  # Validate selected raw journeys and return their observed milliseconds.
  def load_apple_journeys(artifact_path, expected_sha256, journey_ids, corpus_kind:, cache_state:)
    unless expected_sha256.is_a?(String) && /\A\h{64}\z/.match?(expected_sha256)
      raise Error, "Invalid Apple artifact digest"
    end
    unless journey_ids.is_a?(Hash) && journey_ids.keys.to_set == Set["open", "play", "seek"]
      raise Error, "Apple evidence requires open, play and seek identifiers"
    end

    ids = journey_ids.to_h { |name, value| [name, uuid(value)] }
    raise Error, "Apple journey identifiers must be distinct" if ids.values.uniq.length != 3
    unless DOCUMENT_KINDS.key?(corpus_kind) && %w[cold relaunch_warm].include?(cache_state)
      raise Error, "Unsupported Apple evidence context"
    end

    journeys = parse_export(read_artifact(artifact_path, expected_sha256))
    selected = {}
    [%w[open book_open], %w[play progressive_playback], %w[seek seek]].each do |name, kind|
      journey = journeys[ids[name]]
      raise Error, "Selected Apple journey is missing or has the wrong kind" if journey.nil? || journey["kind"] != kind

      selected[name] = journey
    end
    expected_cache = cache_state == "cold" ? "cold" : "prepared_disk"
    if selected["open"]["context"] != { "documentKind" => DOCUMENT_KINDS[corpus_kind], "cacheClass" => expected_cache }
      raise Error, "Apple open context does not match the collection"
    end

    open_boundaries = %w[readable_content controls_usable]
    open_boundaries += %w[first_pdf_page] if corpus_kind != "epub"
    result = timings(selected["open"], "open_requested", open_boundaries)
    result["reader_usable"] = result.values.max
    result.update(timings(selected["play"], "play_requested", %w[audio_queued audio_audible]))
    result.update(timings(selected["seek"], "seek_requested", %w[seek_target_reached]))
  end

  def read_artifact(artifact_path, expected_sha256)
    raw = begin
      File.binread(artifact_path)
    rescue SystemCallError, IOError
      raise Error, "Could not read Apple diagnostic artifact"
    end
    raise Error, "Apple diagnostic artifact digest mismatch" if Digest::SHA256.hexdigest(raw) != expected_sha256.downcase

    raw
  end

  def parse_export(raw)
    payload = begin
      decode_json(raw)
    rescue DuplicateKey
      raise Error, "Duplicate Apple diagnostic field"
    rescue InvalidJson
      raise Error, "Invalid Apple diagnostic JSON"
    end
    raise Error, "Apple diagnostic export must be an array" unless payload.is_a?(Array)

    journeys = {}
    payload.each do |value|
      journey = validate_journey(value)
      identifier = uuid(journey["id"])
      raise Error, "Duplicate Apple journey identifier" if journeys.key?(identifier)

      journeys[identifier] = journey
    end
    journeys
  end
end
