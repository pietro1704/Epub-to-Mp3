# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# The gate runs in the Rust CI job right after `cargo build --release`. Nothing
# in that job creates dist/ any more (the macOS server sidecar build was
# removed), so the gate must pass from the cargo artifacts alone.
class RustMigrationGateTest < Minitest::Test
  GATE = File.expand_path('check_rust_migration_gate.sh', __dir__)

  def setup
    @root = Dir.mktmpdir('rust migration gate ')
    write('Cargo.toml', "[workspace]\nmembers = [\n    \"crates/converter-cli\",\n    \"crates/converter-server\",\n]\n")
    %w[converter-cli converter-server].each do |crate|
      write("crates/#{crate}/Cargo.toml", '[package]')
      write("crates/#{crate}/src/main.rs", 'fn main() {}')
    end
    write('scripts/guard_no_python_production.sh', "#!/bin/sh\n", mode: 0o755)
    write('scripts/check_rust_migration_gate.sh', File.read(GATE), mode: 0o755)
    %w[converter_wasm.js converter_wasm.d.ts converter_wasm_bg.wasm].each { |name| write("web/src/wasm/#{name}", 'x') }
    write('web/src/services/EmbeddedConverter.ts', "import init from '../wasm/converter_wasm';\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_passes_from_the_cargo_artifacts_without_a_dist_directory
    write('target/release/converter-cli', 'x', mode: 0o755)
    write('target/release/converter-server', 'x', mode: 0o755)
    refute File.exist?(File.join(@root, 'dist'))

    output, status = run_gate
    assert status.success?, output
    assert_includes output, 'RESULT PASS'
    refute_includes output, 'dist/'
  end

  def test_still_blocks_when_no_production_artifact_was_built
    FileUtils.mkdir_p(File.join(@root, 'target'))

    output, status = run_gate
    refute status.success?, output
    assert_includes output, 'No generated Rust production artifact found (expected target/release/)'
  end

  def test_still_blocks_when_the_wasm_artifacts_are_missing
    write('target/release/converter-cli', 'x', mode: 0o755)
    FileUtils.rm(File.join(@root, 'web/src/wasm/converter_wasm_bg.wasm'))

    output, status = run_gate
    refute status.success?, output
    assert_includes output, 'Missing browser WASM artifact: web/src/wasm/converter_wasm_bg.wasm'
  end

  private

  def run_gate
    Open3.capture2e('bash', File.join(@root, 'scripts/check_rust_migration_gate.sh'), chdir: @root)
  end

  def write(path, content, mode: 0o644)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
    File.chmod(mode, target)
  end
end
