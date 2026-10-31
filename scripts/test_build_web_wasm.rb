# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class BuildWebWasmTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("web-wasm-build-")
    FileUtils.mkdir_p(%w[scripts bin web/src/wasm].map { |path| File.join(@root, path) })
    FileUtils.cp(File.join(ROOT, "scripts/build_web_wasm.sh"), File.join(@root, "scripts"))
    File.write(File.join(@root, "Cargo.lock"), "[[package]]\nname = \"wasm-bindgen\"\nversion = \"0.2.129\"\n")
    @artifact = File.join(@root, "web/src/wasm/converter_wasm.js")
    File.write(@artifact, "retained artifact")
    @events = File.join(@root, "events")
    shim = File.join(@root, "bin/mise")
    File.write(shim, <<~'SH')
      #!/usr/bin/env bash
      set -euo pipefail
      [[ "$1 $2" == 'exec --' ]] || exit 90
      shift 2
      if [[ "$*" == 'wasm-bindgen --version' ]]; then
        echo "wasm-bindgen ${FIXTURE_VERSION:-0.2.129}"
        exit "${FIXTURE_VERSION_STATUS:-0}"
      fi
      echo "$*" >> "$FIXTURE_EVENTS"
      if [[ "$*" == 'rustup which --toolchain stable rustc' ]]; then
        echo /fixture/rustc
      elif [[ "$1" == rustup ]]; then
        exit "${FIXTURE_BUILD_STATUS:-0}"
      elif [[ "$1" == wasm-bindgen ]]; then
        for suffix in js d.ts _bg.wasm; do
          if [[ "$suffix" == _* ]]; then path="converter_wasm$suffix"; else path="converter_wasm.$suffix"; fi
          echo generated > "web/src/wasm/$path"
        done
      else
        exit 91
      fi
    SH
    File.chmod(0o755, shim)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_build(extra = {})
    Open3.capture3({ "PATH" => "#{@root}/bin:#{ENV.fetch('PATH')}", "FIXTURE_EVENTS" => @events }.merge(extra),
                  "bash", "scripts/build_web_wasm.sh", chdir: @root)
  end

  def test_matching_cli_builds_locked_dependencies_and_generates_artifacts
    _, error, status = run_build
    assert status.success?, error
    assert_includes File.read(@events), "cargo build --locked -p converter-wasm"
    assert_equal "generated\n", File.read(@artifact)
  end

  def test_mismatch_fails_before_compilation_and_preserves_existing_artifacts
    _, error, status = run_build("FIXTURE_VERSION" => "0.2.130")
    refute status.success?
    assert_includes error, "0.2.129"
    assert_includes error, "0.2.130"
    refute File.exist?(@events)
    assert_equal "retained artifact", File.read(@artifact)
  end

  def test_failed_cli_probe_preserves_status_and_artifacts
    _, _, status = run_build("FIXTURE_VERSION_STATUS" => "42")
    assert_equal 42, status.exitstatus
    refute File.exist?(@events)
    assert_equal "retained artifact", File.read(@artifact)
  end

  def test_failed_compilation_does_not_invoke_bindgen
    _, _, status = run_build("FIXTURE_BUILD_STATUS" => "37")
    assert_equal 37, status.exitstatus
    refute_match(/^wasm-bindgen /, File.read(@events))
  end

  def test_cancelled_compilation_does_not_invoke_bindgen
    _, _, status = run_build("FIXTURE_BUILD_STATUS" => "130")
    assert_equal 130, status.exitstatus
    refute_match(/^wasm-bindgen /, File.read(@events))
  end

  def test_missing_locked_schema_fails_before_compilation
    File.write(File.join(@root, "Cargo.lock"), "")
    _, error, status = run_build
    refute status.success?
    assert_includes error, "schema mismatch"
    refute File.exist?(@events)
    assert_equal "retained artifact", File.read(@artifact)
  end

  def test_tool_pin_matches_the_locked_schema
    lock = File.read(File.join(ROOT, "Cargo.lock"))
    version = lock.match(/name = "wasm-bindgen"\nversion = "([^"]+)"/)[1]
    pin = File.read(File.join(ROOT, "mise.toml")).match(/^"cargo:wasm-bindgen-cli" = "([^"]+)"/)[1]
    assert_equal version, pin
  end
end
