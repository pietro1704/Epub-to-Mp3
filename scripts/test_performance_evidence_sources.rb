# frozen_string_literal: true

# Controlled export fixtures test the gate, not product performance.

require "minitest/autorun"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "performance_evidence_gate"

class PerformanceEvidenceSourcesTest < Minitest::Test
  Gate = PerformanceEvidenceGate
  SCRIPT = File.expand_path("performance_evidence_gate.rb", __dir__)

  def self.uuid(number)
    hex = format("%032x", number)
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
  end

  def setup
    @tmp = Dir.mktmpdir("performance-sources")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def capture(index = 0, cache: "cold", reader_ms: 100)
    ids = %w[open play seek].each_with_index.to_h { |name, n| [name, self.class.uuid((index * 4) + n + 1)] }
    context = { "documentKind" => "epub", "cacheClass" => cache == "cold" ? "cold" : "prepared_disk" }
    journeys = [
      ["open", "book_open", [["open_requested", 0], ["readable_content", reader_ms], ["controls_usable", reader_ms]]],
      ["play", "progressive_playback", [["play_requested", 0], ["audio_queued", 50], ["audio_audible", 150]]],
      ["seek", "seek", [["seek_requested", 0], ["seek_target_reached", 75]]]
    ].map do |name, kind, records|
      { "id" => ids[name], "kind" => kind, "context" => context,
        "records" => records.map { |t, ms| { "transition" => t, "elapsedNanoseconds" => ms * 1_000_000 } } }
    end
    payload = JSON.generate(journeys)
    digest = Digest::SHA256.hexdigest(payload)
    FileUtils.mkdir_p(File.join(@tmp, "artifacts"))
    File.binwrite(File.join(@tmp, "artifacts", "#{digest}.json"), payload)
    {
      "client" => "apple", "runner" => "iPhone 16e", "execution_environment" => "physical_device",
      "revision" => "b" * 40, "run_id" => self.class.uuid(index + 10_000), "source_sha256" => digest,
      "journeys" => ids,
      "corpus" => { "kind" => "epub", "sha256" => "a" * 64, "size_bytes" => 1000, "page_count" => 10 },
      "cache_state" => cache, "resource_policy" => "normal"
    }
  end

  def bundle(captures)
    File.join(@tmp, "evidence.json").tap do |path|
      File.write(path, JSON.generate("schema_version" => 2, "captures" => captures))
    end
  end

  def report(path, **)
    Gate.evaluate(Gate.load_evidence(path).samples, clients: ["apple"], corpora: ["epub"], **)
  end

  def cold_and_warm
    [["cold", 0], ["relaunch_warm", 20]].flat_map do |state, start|
      (start...(start + 20)).map { |i| capture(i, cache: state) }
    end
  end

  %i[clients corpora cache_states].each do |dimension|
    define_method("test_empty_selection_cannot_pass_#{dimension}") do
      error = assert_raises(Gate::EvidenceError) { Gate.evaluate([], dimension => []) }
      assert_match(/non-empty/, error.message)
    end
  end

  { "0" => 0, "1" => 1, "19" => 19, "true" => true, "20_5" => 20.5 }.each do |label, count|
    define_method("test_cannot_lower_twenty_repetition_requirement_#{label}") do
      assert_raises(Gate::EvidenceError) { Gate.evaluate([], required_samples: count) }
    end
  end

  def test_import_derives_boundaries_and_preserves_source_metadata
    sample = capture
    result = report(bundle([sample]))
    cold = result["buckets"][0]
    assert_equal 1, cold["sample_count"]
    assert_equal "a" * 64, cold["corpus_sha256"]
    assert_equal "iPhone 16e", cold["runner"]
    assert_equal "normal", cold["resource_policy"]
    assert_equal 50, cold["boundaries"]["audio_queued"]["p95_ms"]
    assert_equal 150, cold["boundaries"]["audio_audible"]["p95_ms"]
    assert_equal 75, cold["boundaries"]["seek_target_reached"]["p95_ms"]
    assert_equal [sample["source_sha256"]], cold["sources"]
    assert_equal "pending", result["status"]
  end

  def test_reused_journeys_and_process_runs_are_rejected
    first = capture
    duplicate = Marshal.load(Marshal.dump(first))
    duplicate["run_id"] = self.class.uuid(99_999)
    error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(bundle([first, duplicate])) }
    assert_match(/reused/, error.message)
    second = capture(1)
    second["run_id"] = first["run_id"]
    error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(bundle([first, second])) }
    assert_match(/reused/, error.message)
  end

  %w[corpus runner resource_policy revision].each do |dimension|
    define_method("test_capture_conditions_cannot_pool_repetitions_#{dimension}") do
      samples = (0...20).map { |i| capture(i) }
      samples[10..].each do |sample|
        if dimension == "corpus"
          sample["corpus"]["sha256"] = "c" * 64
        else
          sample[dimension] = { "runner" => "iPad", "resource_policy" => "resource_constrained",
                                "revision" => "d" * 40 }.fetch(dimension)
        end
      end
      result = report(bundle(samples), cache_states: ["cold"])
      assert_equal [10, 10], result["buckets"].map { |b| b["sample_count"] }
      assert_equal "pending", result["status"]
      assert_equal 2, result["missing"].length
    end
  end

  [["0_1", 0.1], ["1_5", 1.5], ["true", true], ["0", 0]].each do |label, value|
    %w[size_bytes page_count].each do |field|
      define_method("test_corpus_counts_require_positive_integers_#{field}_#{label}") do
        sample = capture
        sample["corpus"][field] = value
        error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(bundle([sample])) }
        assert_match(/positive integer/, error.message)
      end
    end
  end

  def test_source_hash_is_verified
    sample = capture
    File.write(File.join(@tmp, "artifacts", "#{sample['source_sha256']}.json"), "[]")
    error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(bundle([sample])) }
    assert_match(/digest/, error.message)
  end

  def test_observations_cannot_substitute_for_release_evidence
    result = report(bundle(cold_and_warm))
    assert_equal "passed", result["observations_status"]
    assert_equal "pending", result["status"]
    assert_includes result["pending_requirements"], "conversion_output_integrity_cli"
    assert_includes result["pending_requirements"], "automated_collection_lifecycle"
  end

  def test_budget_failure_names_boundary_despite_missing_other_evidence
    samples = (0...20).map { |i| capture(i, cache: "relaunch_warm", reader_ms: 250 + i) }
    result = report(bundle(samples))
    assert_equal "failed", result["status"]
    assert_equal 259.5, result["buckets"][1]["boundaries"]["reader_usable"]["p50_ms"]
    assert_equal "reader_usable", result["optimization_queue"][0]["boundary"]
    assert_equal 268.05, result["optimization_queue"][0]["p95_ms"]
  end

  def test_cold_and_warm_require_matching_corpus_conditions
    samples = cold_and_warm
    samples[20..].each { |sample| sample["corpus"]["sha256"] = "c" * 64 }
    result = report(bundle(samples))
    assert_equal "pending", result["observations_status"]
    assert_equal 2, result["missing"].length
  end

  def test_budget_uses_unrounded_percentile
    samples = (0...20).map { |i| capture(i, cache: "relaunch_warm", reader_ms: 200) }
    loaded = Gate.load_evidence(bundle(samples)).samples.to_a
    loaded.each { |sample| sample.boundaries_ms["reader_usable"] = 200.000001 }
    result = Gate.evaluate(loaded, clients: ["apple"], corpora: ["epub"])
    assert_equal "failed", result["status"]
  end

  def test_strict_cli_reports_pending
    code = nil
    out, _err = capture_io { code = Gate.main([bundle([capture]), "--strict"]) }
    assert_equal 1, code
    assert_includes out, '"status": "pending"'
  end

  def test_script_imports_original_capture_and_writes_pending_report
    manifest = bundle([capture])
    output = File.join(@tmp, "report.json")
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, manifest, "--output", output, "--strict")
    assert_equal 1, status.exitstatus
    result = JSON.parse(File.read(output))
    assert_equal JSON.parse(stdout), result
    assert_equal 150, result["buckets"][0]["boundaries"]["audio_audible"]["p95_ms"]
    assert_equal "pending", result["status"]
  end

  # Ruby-only: the failed report keeps Python's exceeded/queue shape and key order.
  def test_exceeded_entries_and_queue_order_match_python
    samples = (0...20).map { |i| capture(i, cache: "relaunch_warm", reader_ms: 250 + i) }
    result = report(bundle(samples))
    entry = result["budget_exceeded"].first
    assert_equal %w[client corpus cache_state sample_count corpus_sha256 corpus_size_bytes corpus_page_count runner
                    execution_environment revision resource_policy budget_ms within_budget boundary p95_ms], entry.keys
    assert_equal false, entry["within_budget"]
    assert_equal 1, result["budget_exceeded"].length
    assert_equal false, result["buckets"][1]["within_budget"]
    assert_equal 200, result["buckets"][1]["budget_ms"]
    assert_equal "failed", result["observations_status"]
    queue = Gate.evaluate([], clients: ["apple"]).fetch("optimization_queue")
    assert_equal [], queue
  end
end
