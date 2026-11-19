# frozen_string_literal: true

# Verify raw Apple export ingestion without asserting product performance.

require "minitest/autorun"
require "digest"
require "json"
require "tmpdir"
require "fileutils"
require_relative "apple_latency_evidence"

class AppleLatencyEvidenceTest < Minitest::Test
  Error = AppleLatencyEvidence::Error
  PRIVATE = "PRIVATE_BOOK_CONTENT"

  def self.uuid(number)
    hex = format("%032x", number)
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
  end

  PUBLICATION_IDS = [
    "0123456789abcdef0123456789abcdef", "0123456789ABCDEF0123456789ABCDEF",
    "123e4567-e89b-12d3-a456-426614174000", "123E4567-E89B-12D3-A456-426614174000",
    "0", "12345678901234567890"
  ].freeze
  INVALID_PUBLICATION_IDS = [nil, true, 12, "", PRIVATE, "١٢٣", "123456789012345678901", "g" * 32,
                             "{#{uuid(1)}}"].freeze

  def self.name_for(value)
    value.inspect.gsub(/[^A-Za-z0-9]+/, "_")
  end

  def setup
    @tmp = Dir.mktmpdir("apple-latency")
    @export = [
      ["book_open", %w[open_requested readable_content controls_usable]],
      ["progressive_playback", %w[play_requested audio_queued audio_audible]],
      ["seek", %w[seek_requested seek_target_reached]]
    ].each_with_index.map do |(kind, transitions), offset|
      index = offset + 1
      {
        "id" => self.class.uuid(index),
        "kind" => kind,
        "context" => { "documentKind" => "epub", "cacheClass" => index == 1 ? "cold" : "unknown" },
        "records" => transitions.each_with_index.map do |transition, step|
          { "transition" => transition, "elapsedNanoseconds" => step * 1_000_000 }
        end
      }
    end
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def load(export = @export, corpus: "epub", cache: "cold", raw: nil, digest: nil, ids: nil)
    path = File.join(@tmp, "capture.json")
    data = raw.nil? ? JSON.generate(export, allow_nan: true) : raw
    File.binwrite(path, data)
    ids ||= %w[open play seek].zip(export).to_h { |name, item| [name, item["id"]] }
    AppleLatencyEvidence.load_apple_journeys(
      path, digest || Digest::SHA256.hexdigest(data), ids, corpus_kind: corpus, cache_state: cache
    )
  end

  def publication
    {
      "publicationId" => "0123456789abcdef0123456789abcdef",
      "producer" => {
        "version" => 1,
        "attemptId" => "123e4567-e89b-12d3-a456-426614174000",
        "segmentReadyElapsedNanoseconds" => 9_000_000_000,
        "artifactPublishedElapsedNanoseconds" => 10_000_000_000
      }
    }
  end

  def stream_request(journey, identifier = "0123456789abcdef0123456789abcdef")
    { "journeyId" => journey["id"], "requestId" => "123e4567-e89b-12d3-a456-426614174001",
      "publicationId" => identifier }
  end

  def assert_redacted(pattern = nil, &block)
    error = assert_raises(Error, &block)
    assert_match(pattern, error.message) if pattern
    refute_includes error.message, PRIVATE
    refute_includes error.message, @tmp
    error
  end

  def test_epub_derives_separate_observed_boundaries
    expected = { "readable_content" => 1.0, "controls_usable" => 2.0, "reader_usable" => 2.0,
                 "audio_queued" => 1.0, "audio_audible" => 2.0, "seek_target_reached" => 1.0 }
    result = load
    assert_equal expected, result
    assert_equal expected.keys, result.keys
    assert(result.values.all?(Float))
  end

  [false, true].each do |with_producer|
    PUBLICATION_IDS.each do |identifier|
      define_method("test_stream_request_preserves_client_timings_#{name_for(identifier)}_#{with_producer}") do
        expected = load
        [1, 2].each do |index|
          @export[index]["streamRequest"] = stream_request(@export[index], identifier)
          @export[index]["streamPublication"] = publication.merge("publicationId" => identifier) if with_producer
        end
        assert_equal expected, load
      end
    end
  end

  def test_stream_request_uuid_comparison_is_case_insensitive
    @export[1]["id"] = "123e4567-e89b-12d3-a456-426614174002"
    @export[1]["streamRequest"] = stream_request(@export[1])
    @export[1]["streamRequest"]["journeyId"] = @export[1]["id"].upcase
    @export[1]["streamRequest"]["requestId"] = @export[1]["streamRequest"]["requestId"].upcase
    assert_equal 2, load["audio_audible"]
  end

  [nil, true, 7, "", PRIVATE, "0" * 32, "{#{uuid(1)}}", "urn:uuid:#{uuid(1)}"].each do |value|
    %w[journeyId requestId].each do |field|
      define_method("test_stream_request_invalid_uuid_is_redacted_#{field}_#{name_for(value)}") do
        @export[1]["streamRequest"] = stream_request(@export[1]).merge(field => value)
        assert_redacted { load }
      end
    end
  end

  INVALID_PUBLICATION_IDS.each_with_index do |identifier, position|
    define_method("test_stream_request_invalid_publication_is_redacted_#{position}") do
      @export[2]["streamRequest"] = stream_request(@export[2], identifier)
      assert_redacted { load }
    end

    define_method("test_invalid_publication_identity_is_redacted_#{position}") do
      @export[1]["streamPublication"] = publication.merge("publicationId" => identifier)
      assert_redacted { load }
    end
  end

  def test_invalid_publication_fixture_uses_braced_uuid
    assert_equal "{#{self.class.uuid(1)}}", INVALID_PUBLICATION_IDS.last
  end

  %w[open null extra missing journey_mismatch publication_mismatch publication_case_mismatch
     unknown_journey_field].each do |mutation|
    define_method("test_stream_request_schema_and_correlation_are_strict_#{mutation}") do
      index = mutation == "open" ? 0 : 1
      metadata = stream_request(@export[index])
      case mutation
      when "null" then metadata = nil
      when "extra" then metadata["text"] = PRIVATE
      when "missing" then metadata.delete("requestId")
      when "journey_mismatch" then metadata["journeyId"] = @export[2]["id"]
      when "publication_mismatch", "publication_case_mismatch"
        @export[index]["streamPublication"] = publication
        metadata["publicationId"] = mutation == "publication_mismatch" ? "0" : metadata["publicationId"].upcase
      when "unknown_journey_field" then @export[index]["title"] = PRIVATE
      end
      @export[index]["streamRequest"] = metadata
      error = assert_raises(Error) { load }
      refute_includes error.message, PRIVATE
    end
  end

  %w[journeyId requestId publicationId].each do |field|
    define_method("test_stream_request_duplicate_nested_fields_are_rejected_#{field}") do
      metadata = stream_request(@export[1])
      @export[1]["streamRequest"] = metadata
      original = "#{JSON.generate(field)}:#{JSON.generate(metadata[field])}"
      raw = JSON.generate(@export)
      assert_includes raw, original
      error = assert_raises(Error) { load(raw: raw.sub(original, "#{original},#{original}")) }
      assert_match(/Duplicate/, error.message)
    end
  end

  PUBLICATION_IDS.each do |identifier|
    define_method("test_publication_metadata_does_not_change_client_timings_#{name_for(identifier)}") do
      legacy = load
      [1, 2].each { |index| @export[index]["streamPublication"] = publication.merge("publicationId" => identifier) }
      assert_equal legacy, load
    end
  end

  [
    ["version", true], ["version", 1.0], ["version", 2],
    ["attemptId", PRIVATE], ["attemptId", "0" * 32], ["attemptId", nil],
    ["segmentReadyElapsedNanoseconds", true], ["segmentReadyElapsedNanoseconds", -1],
    ["segmentReadyElapsedNanoseconds", 1.5], ["segmentReadyElapsedNanoseconds", "1"],
    ["segmentReadyElapsedNanoseconds", 2**64], ["segmentReadyElapsedNanoseconds", nil],
    ["artifactPublishedElapsedNanoseconds", 1], ["artifactPublishedElapsedNanoseconds", 2**64],
    ["artifactPublishedElapsedNanoseconds", true], ["artifactPublishedElapsedNanoseconds", Float::NAN]
  ].each_with_index do |(field, value), position|
    define_method("test_invalid_producer_metadata_is_redacted_#{position}_#{field}") do
      metadata = publication
      metadata["producer"][field] = value
      @export[2]["streamPublication"] = metadata
      error = assert_raises(Error) { load }
      refute_includes error.message, PRIVATE
    end
  end

  %w[open null extra missing producer_extra producer_missing].each do |mutation|
    define_method("test_publication_schema_and_allowed_journey_are_strict_#{mutation}") do
      metadata = publication
      case mutation
      when "null" then metadata = nil
      when "extra" then metadata["title"] = PRIVATE
      when "missing" then metadata.delete("producer")
      when "producer_extra" then metadata["producer"]["text"] = PRIVATE
      when "producer_missing" then metadata["producer"].delete("attemptId")
      end
      @export[mutation == "open" ? 0 : 1]["streamPublication"] = metadata
      error = assert_raises(Error) { load }
      refute_includes error.message, PRIVATE
    end
  end

  [0, (2**64) - 1].each do |elapsed|
    define_method("test_producer_unsigned_boundaries_remain_separate_from_client_clock_#{elapsed}") do
      expected = load
      metadata = publication
      metadata["producer"]["segmentReadyElapsedNanoseconds"] = elapsed
      metadata["producer"]["artifactPublishedElapsedNanoseconds"] = elapsed
      @export[1]["streamPublication"] = metadata
      assert_equal expected, load
    end
  end

  def test_duplicate_nested_producer_fields_remain_rejected
    @export[1]["streamPublication"] = publication
    raw = JSON.generate(@export)
    assert_includes raw, '"version":1'
    error = assert_raises(Error) { load(raw: raw.sub('"version":1', '"version":1,"version":1')) }
    assert_match(/Duplicate/, error.message)
  end

  def test_publication_does_not_enable_unknown_journey_fields
    @export[1]["streamPublication"] = publication
    @export[1]["title"] = PRIVATE
    assert_redacted(/fields/) { load }
  end

  [%w[selectable_text_pdf selectable_text_pdf], %w[sideways_two_up_scanned_pdf normalized_scanned_pdf]].each do |corpus, document|
    define_method("test_pdf_requires_corrected_first_page_for_reader_usability_#{corpus}") do
      @export[0]["context"]["documentKind"] = document
      error = assert_raises(Error) { load(corpus: corpus) }
      assert_match(/incomplete/, error.message)
      @export[0]["records"] << { "transition" => "first_pdf_page", "elapsedNanoseconds" => 9_000_000 }
      result = load(corpus: corpus)
      assert_equal 9, result["reader_usable"]
      assert_equal 9, result["first_pdf_page"]
    end
  end

  def test_warm_requires_prepared_disk_context
    @export[0]["context"]["cacheClass"] = "in_memory_warm"
    error = assert_raises(Error) { load(cache: "relaunch_warm") }
    assert_match(/context/, error.message)
    @export[0]["context"]["cacheClass"] = "prepared_disk"
    assert_equal 2, load(cache: "relaunch_warm")["reader_usable"]
  end

  [0, 1, 2].each do |index|
    define_method("test_selected_cancelled_or_incomplete_journey_is_rejected_#{index}") do
      final = @export[index]["records"].pop
      assert_match(/incomplete/, assert_raises(Error) { load }.message)
      @export[index]["records"] << final.merge("transition" => "cancelled")
      assert_match(/cancelled/, assert_raises(Error) { load }.message)
    end
  end

  def test_unselected_cancelled_journey_does_not_discard_valid_capture
    @export << {
      "id" => self.class.uuid(9), "kind" => "seek",
      "context" => { "documentKind" => "epub", "cacheClass" => "unknown" },
      "records" => [{ "transition" => "seek_requested", "elapsedNanoseconds" => 0 },
                    { "transition" => "cancelled", "elapsedNanoseconds" => 1 }]
    }
    assert_equal 1, load["seek_target_reached"]
  end

  def test_queue_must_precede_audible_even_when_timestamps_tie
    @export[1]["records"][1..] = [{ "transition" => "audio_audible", "elapsedNanoseconds" => 1 },
                                  { "transition" => "audio_queued", "elapsedNanoseconds" => 1 }]
    assert_match(/precedes/, assert_raises(Error) { load }.message)
  end

  [true, -1, 0.1, "100", nil, 2**64, Float::NAN, Float::INFINITY].each do |elapsed|
    define_method("test_elapsed_requires_unsigned_integer_nanoseconds_#{name_for(elapsed)}") do
      @export[0]["records"][1]["elapsedNanoseconds"] = elapsed
      assert_match(/timing/, assert_raises(Error) { load }.message)
    end
  end

  def test_decreasing_and_nonzero_initial_timing_rejected
    @export[0]["records"][2]["elapsedNanoseconds"] = 1
    assert_match(/timing/, assert_raises(Error) { load }.message)
    @export[0]["records"][2]["elapsedNanoseconds"] = 2_000_000
    @export[0]["records"][0]["elapsedNanoseconds"] = 1
    assert_match(/initial/, assert_raises(Error) { load }.message)
  end

  def test_duplicate_global_and_selected_ids_rejected
    @export << @export[0]
    assert_match(/Duplicate.*identifier/, assert_raises(Error) { load }.message)
    @export.pop
    ids = %w[open play seek].to_h { |name| [name, @export[0]["id"]] }
    assert_match(/distinct/, assert_raises(Error) { load(ids: ids) }.message)
  end

  def test_duplicate_json_keys_rejected
    raw = JSON.generate(@export).sub('"kind":"book_open"', '"kind":"book_open","kind":"book_open"')
    assert_match(/Duplicate.*field/, assert_raises(Error) { load(raw: raw) }.message)
  end

  %w[journey context record].each do |level|
    define_method("test_unknown_privacy_fields_rejected_without_echoing_value_#{level}") do
      target = { "journey" => @export[0], "context" => @export[0]["context"],
                 "record" => @export[0]["records"][0] }.fetch(level)
      target["title"] = PRIVATE
      assert_redacted(/fields/) { load }
    end
  end

  { "truncated" => "{", "invalid_utf8" => "\xFF".b, "object" => "{}", "null" => "null" }.each do |label, raw|
    define_method("test_invalid_artifact_json_is_redacted_#{label}") do
      error = assert_raises(Error) { load(raw: raw) }
      refute_includes error.message, @tmp
    end
  end

  def test_missing_file_and_hash_mismatch_are_redacted
    ids = %w[open play seek].zip(@export).to_h { |name, item| [name, item["id"]] }
    error = assert_raises(Error) do
      AppleLatencyEvidence.load_apple_journeys(File.join(@tmp, "PRIVATE_NAME.json"), "a" * 64, ids,
                                               corpus_kind: "epub", cache_state: "cold")
    end
    assert_match(/read/, error.message)
    refute_includes error.message, "PRIVATE_NAME"
    assert_match(/digest mismatch/, assert_raises(Error) { load(digest: "a" * 64) }.message)
  end

  def test_wrong_kind_and_unknown_transition_rejected
    @export[0]["records"][1]["transition"] = "unrecognized"
    assert_match(/transition/, assert_raises(Error) { load }.message)
    @export[0]["records"][1]["transition"] = "readable_content"
    ids = { "open" => @export[1]["id"], "play" => @export[0]["id"], "seek" => @export[2]["id"] }
    assert_match(/wrong kind/, assert_raises(Error) { load(ids: ids) }.message)
  end

  # Ruby-only parity checks for Python json.loads(bytes) behavior.
  def test_python_json_byte_decoding_parity
    assert_equal [1], AppleLatencyEvidence.decode_json("\xEF\xBB\xBF[1]".b)
    assert_equal [1], AppleLatencyEvidence.decode_json("[1]".encode("UTF-16LE").b)
    assert_equal [1], AppleLatencyEvidence.decode_json("\xFF\xFE".b + "[1]".encode("UTF-16LE").b)
    assert_equal [1], AppleLatencyEvidence.decode_json("[1]".encode("UTF-32BE").b)
    assert AppleLatencyEvidence.decode_json("[NaN]").first.nan?
    assert_raises(AppleLatencyEvidence::DuplicateKey) { AppleLatencyEvidence.decode_json('{"a":1,"a":1}') }
    ["[1,]", "[1 /* c */]", "[\"a\tb\"]", "\"\xFF\"".b, ""].each do |raw|
      assert_raises(AppleLatencyEvidence::InvalidJson) { AppleLatencyEvidence.decode_json(raw) }
    end
  end

  def test_large_nanoseconds_divide_exactly
    value = (2**64) - 1
    assert_equal 18_446_744_073_709.551615.to_f, value.fdiv(1_000_000)
  end

  def test_invalid_digest_and_context_are_rejected_before_reading
    ids = { "open" => self.class.uuid(1), "play" => self.class.uuid(2), "seek" => self.class.uuid(3) }
    missing = File.join(@tmp, "missing.json")
    assert_match(/digest/, assert_raises(Error) do
      AppleLatencyEvidence.load_apple_journeys(missing, "z" * 64, ids, corpus_kind: "epub", cache_state: "cold")
    end.message)
    assert_match(/context/, assert_raises(Error) do
      AppleLatencyEvidence.load_apple_journeys(missing, "a" * 64, ids, corpus_kind: "epub", cache_state: "warm")
    end.message)
    assert_match(/open, play and seek/, assert_raises(Error) do
      AppleLatencyEvidence.load_apple_journeys(missing, "a" * 64, ids.except("seek"), corpus_kind: "epub",
                                                                                      cache_state: "cold")
    end.message)
  end
end
