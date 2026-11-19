# frozen_string_literal: true

# CLI and legacy-summary rejection checks for the evidence importer.

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "performance_evidence_gate"

class PerformanceEvidenceGateTest < Minitest::Test
  Gate = PerformanceEvidenceGate
  SCRIPT = File.expand_path("performance_evidence_gate.rb", __dir__)

  def setup
    @tmp = Dir.mktmpdir("performance-gate")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def write(name, text)
    File.join(@tmp, name).tap { |path| File.write(path, text) }
  end

  def run_script(*arguments, env: {})
    Open3.capture3(env, RbConfig.ruby, SCRIPT, *arguments, chdir: @tmp)
  end

  def usage_error(message)
    "#{Gate::Cli.usage('performance_evidence_gate.rb', 78)}performance_evidence_gate.rb: error: #{message}\n"
  end

  def test_legacy_boolean_integrity_is_not_release_evidence
    path = write("legacy.json", JSON.generate(
                                  "schema_version" => 1, "samples" => [],
                                  "conversion_integrity" => { "cli" => true, "server" => true }
                                ))
    error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(path) }
    assert_match(/schema_version/, error.message)
  end

  def test_unknown_manifest_fields_are_rejected_without_echoing_private_data
    path = write("manifest.json", JSON.generate("schema_version" => 2, "captures" => [], "title" => "PRIVATE BOOK"))
    code = nil
    _out, err = capture_io { code = Gate.main([path]) }
    assert_equal 2, code
    refute_includes err, "PRIVATE BOOK"
    assert_equal "performance_evidence_gate: manifest has missing or unsupported fields\n", err
  end

  def test_duplicate_json_fields_are_rejected
    path = write("manifest.json", '{"schema_version":2,"captures":[],"captures":[]}')
    error = assert_raises(Gate::EvidenceError) { Gate.load_evidence(path) }
    assert_match(/duplicate/, error.message)
  end

  { "inf" => Float::INFINITY, "nan" => Float::NAN, "true" => true, "zero" => 0, "negative" => -1 }.each do |label, budget|
    define_method("test_invalid_budgets_cannot_suppress_failures_#{label}") do
      assert_raises(Gate::EvidenceError) { Gate.evaluate([], warm_budget_ms: budget) }
    end
  end

  def test_percentile_uses_interpolation_and_rejects_empty_values
    assert_in_delta 18.05, Gate.percentile(0...20, 0.95), 1e-9
    assert_raises(Gate::EvidenceError) { Gate.percentile([], 0.95) }
  end

  def test_script_entry_point_emits_pending_and_strict_failure
    path = write("empty.json", '{"schema_version":2,"captures":[]}')
    stdout, _stderr, status = run_script(path, "--strict")
    assert_equal 1, status.exitstatus
    payload = JSON.parse(stdout)
    assert_equal "pending", payload["status"]
    assert_equal 18, payload["missing"].length
  end

  # Ruby-only checks for the Python json.dumps and argparse contract.

  def test_output_matches_python_json_dumps_layout
    path = write("empty.json", '{"schema_version":2,"captures":[]}')
    stdout, stderr, status = run_script(path, "--clients", "apple", "--corpora", "epub", "--cache-states", "cold")
    assert_equal 0, status.exitstatus
    assert_equal "", stderr
    assert_equal <<~JSON, stdout
      {
        "buckets": [
          {
            "cache_state": "cold",
            "client": "apple",
            "corpus": "epub",
            "sample_count": 0
          }
        ],
        "budget_exceeded": [],
        "evidence_class": "imported_diagnostics_not_verified_collection",
        "missing": [
          {
            "cache_state": "cold",
            "client": "apple",
            "corpus": "epub",
            "required_sample_count": 20,
            "sample_count": 0
          }
        ],
        "observations_status": "pending",
        "optimization_queue": [],
        "pending_requirements": [
          "automated_collection_lifecycle",
          "representative_corpus_verification",
          "streaming_backend_correlation",
          "conversion_output_integrity_cli",
          "conversion_output_integrity_server",
          "web_profile_collection",
          "flutter_profile_collection"
        ],
        "requirements": {
          "cache_states": [
            "cold"
          ],
          "clients": [
            "apple"
          ],
          "cold_budget_ms": 1000,
          "corpora": [
            "epub"
          ],
          "samples_per_bucket": 20,
          "warm_budget_ms": 200
        },
        "schema_version": 2,
        "status": "pending"
      }
    JSON
  end

  def test_python_json_scalars_and_rounding
    dump = ->(value) { PythonJson.dump(value) }
    assert_equal "150.0", dump.call(150.0)
    assert_equal "268.05", dump.call(268.05)
    assert_equal "1e+16", dump.call(1e16)
    assert_equal "1.5e-05", dump.call(1.5e-5)
    assert_equal "NaN", dump.call(Float::NAN)
    assert_equal "-Infinity", dump.call(-Float::INFINITY)
    assert_equal '"\\u00e9\\ud83d\\ude00\\n\\u007f"', dump.call("é😀\n\x7F")
    assert_equal '{"b": {}, "a": [1, null]}', dump.call("b" => {}, "a" => [1, nil])
    assert_equal '{"a": [1, null], "b": {}}', PythonJson.dump({ "b" => {}, "a" => [1, nil] }, sort_keys: true)
    assert_equal 0.062, Gate.python_round(0.0625, 3)
    assert_equal 2.67, Gate.python_round(2.675, 2)
    assert_equal 259.5, Gate.python_round(259.5, 3)
    assert_equal "-0.0", Gate.python_round(-0.0001, 3).to_s
  end

  def test_unreadable_manifest_and_unwritable_output_are_redacted
    stdout, stderr, status = run_script(File.join(@tmp, "PRIVATE_NAME.json"))
    assert_equal [2, "", "performance_evidence_gate: could not read evidence manifest\n"],
                 [status.exitstatus, stdout, stderr]
    path = write("empty.json", '{"schema_version":2,"captures":[]}')
    blocker = write("blocker", "")
    stdout, stderr, status = run_script(path, "--output", File.join(blocker, "report.json"))
    assert_equal [2, "", "performance_evidence_gate: could not write report\n"], [status.exitstatus, stdout, stderr]
  end

  def test_argparse_errors_exit_two_with_usage
    {
      [] => "the following arguments are required: evidence",
      %w[a b --unknown] => "unrecognized arguments: b --unknown",
      %w[a --samples abc] => "argument --samples: invalid int value: 'abc'",
      %w[a --samples] => "argument --samples: expected one argument",
      %w[a --output --strict] => "argument --output: expected one argument",
      %w[a --c x] => "ambiguous option: --c could match --clients, --corpora, --cache-states",
      %w[a --strict=yes] => "argument --strict: ignored explicit argument 'yes'",
      %w[a -hx] => "argument -h/--help: ignored explicit argument 'x'"
    }.each do |arguments, message|
      stdout, stderr, status = run_script(*arguments, env: { "COLUMNS" => "80" })
      assert_equal [2, "", usage_error(message)], [status.exitstatus, stdout, stderr], arguments.inspect
    end
  end

  def test_argparse_options_selection_and_help
    path = write("empty.json", '{"schema_version":2,"captures":[]}')
    stdout, _stderr, status = run_script("--samp=21", "--cl", "apple", "--corp=epub", "--", path)
    assert_equal 0, status.exitstatus
    assert_equal 21, JSON.parse(stdout)["requirements"]["samples_per_bucket"]
    assert_equal 2, JSON.parse(stdout)["buckets"].length
    _stdout, stderr, status = run_script(path, "--clients", "apple,apple")
    assert_equal [2, "performance_evidence_gate: required selections must be non-empty, supported and unique\n"],
                 [status.exitstatus, stderr]
    _stdout, stderr, status = run_script(path, "--samples", "19")
    assert_equal [2, "performance_evidence_gate: required_samples must be an integer of at least 20\n"],
                 [status.exitstatus, stderr]
    stdout, stderr, status = run_script("--help", env: { "COLUMNS" => "80" })
    assert_equal [0, ""], [status.exitstatus, stderr]
    assert stdout.start_with?(Gate::Cli.usage("performance_evidence_gate.rb", 78))
    assert_includes stdout, "\n\nImport source-backed observations without claiming an unmeasured release gate.\n\n"
    assert_includes stdout, "  --strict              Fail until release evidence is complete\n"
  end
end
