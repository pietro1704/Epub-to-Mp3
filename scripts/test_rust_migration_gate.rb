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
    # The browser WASM is built by the Rails gateway (nothing generated is committed).
    write('crates/converter-wasm/Cargo.toml', '[package]')
    write('ruby_app/rails_gateway/bin/build-runtime-wasm', "#!/bin/sh\n", mode: 0o755)
    write('ruby_app/rails_gateway/bin/assemble-runtime', "#!/bin/sh\n", mode: 0o755)
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

  def test_still_blocks_when_the_gateway_wasm_build_is_missing
    write('target/release/converter-cli', 'x', mode: 0o755)
    FileUtils.rm(File.join(@root, 'ruby_app/rails_gateway/bin/build-runtime-wasm'))

    output, status = run_gate
    refute status.success?, output
    assert_includes output, 'Missing gateway WASM build script: ruby_app/rails_gateway/bin/build-runtime-wasm'
  end

  def test_still_blocks_when_the_wasm_crate_or_runtime_assembly_is_missing
    write('target/release/converter-cli', 'x', mode: 0o755)
    FileUtils.rm(File.join(@root, 'crates/converter-wasm/Cargo.toml'))
    FileUtils.rm(File.join(@root, 'ruby_app/rails_gateway/bin/assemble-runtime'))

    output, status = run_gate
    refute status.success?, output
    assert_includes output, 'Missing WASM crate manifest: crates/converter-wasm/Cargo.toml'
    assert_includes output, 'Missing gateway runtime assembly script: ruby_app/rails_gateway/bin/assemble-runtime'
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
