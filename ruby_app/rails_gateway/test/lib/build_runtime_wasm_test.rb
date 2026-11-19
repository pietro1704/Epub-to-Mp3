require "test_helper"
require "open3"

# Runs the real build script in an isolated workspace whose cargo and
# wasm-bindgen are recording stand-ins; no compiler is started.
class BuildRuntimeWasmTest < ActiveSupport::TestCase
  LOCKED_VERSION = "0.2.129".freeze

  setup do
    @workspace = Pathname(Dir.mktmpdir("build-runtime-wasm-")).realpath
    @script = @workspace.join("ruby_app/rails_gateway/bin/build-runtime-wasm")
    @tools = @workspace.join("tools").tap(&:mkpath)
    @events = @workspace.join("events")
    @output = @workspace.join("out/wasm")
    @script.dirname.mkpath
    FileUtils.cp(Rails.root.join("bin/build-runtime-wasm"), @script)
    @workspace.join("Cargo.lock").write("[[package]]\nname = \"wasm-bindgen\"\nversion = \"#{LOCKED_VERSION}\"\n")
    stand_in("cargo", 'echo "cargo $* (in $PWD)" >> "$FIXTURE_EVENTS"; exit "${FIXTURE_CARGO_STATUS:-0}"')
    stand_in("wasm-bindgen", <<~'SH')
      if [[ "$*" == "--version" ]]; then echo "wasm-bindgen ${FIXTURE_CLI_VERSION}"; exit 0; fi
      echo "wasm-bindgen $*" >> "$FIXTURE_EVENTS"
      [[ "${FIXTURE_SKIP_OUTPUT:-}" == 1 ]] && exit 0
      out="${@: -1}"
      echo "generated glue" > "$out/converter_wasm.js"
      echo "generated module" > "$out/converter_wasm_bg.wasm"
    SH
  end

  teardown { FileUtils.remove_entry(@workspace) }

  test "builds the locked crate for the browser and writes only the bindings to the output directory" do
    target = @workspace.join("cargo output")
    _, error, status = build("CARGO_TARGET_DIR" => nil, "CARGO_BUILD_TARGET_DIR" => target.to_s)

    assert status.success?, error
    events = @events.read
    assert_includes events, "cargo build --locked -p converter-wasm --target wasm32-unknown-unknown --release --jobs 1 (in #{@workspace})"
    assert_includes events, "wasm-bindgen #{target}/wasm32-unknown-unknown/release/converter_wasm.wasm"
    assert_includes events, "--target web --no-typescript --out-dir #{@output}"
    assert_equal %w[converter_wasm.js converter_wasm_bg.wasm], @output.children.map { |file| file.basename.to_s }.sort
    assert_empty @workspace.glob("ruby_app/**/*.wasm") + @workspace.glob("web/**/*")
  end

  test "refuses a wasm-bindgen CLI that does not match Cargo.lock before compiling" do
    _, error, status = build("FIXTURE_CLI_VERSION" => "0.2.100")

    refute status.success?
    assert_includes error, "wasm-bindgen schema mismatch: Cargo.lock=#{LOCKED_VERSION}; CLI=wasm-bindgen 0.2.100"
    refute_predicate @events, :exist?
  end

  test "fails when the compiler fails or the bindings are not produced" do
    _, _, status = build("FIXTURE_CARGO_STATUS" => "101")
    refute status.success?

    _, error, status = build("FIXTURE_SKIP_OUTPUT" => "1")
    refute status.success?
    assert_includes error, "missing or empty WASM artifact"
  end

  test "requires an output directory" do
    _, _, status = Open3.capture3(environment, "bash", @script.to_s)

    refute status.success?
  end

  private

  def environment(extra = {})
    { "PATH" => "#{@tools}:/usr/bin:/bin", "FIXTURE_EVENTS" => @events.to_s, "FIXTURE_CLI_VERSION" => LOCKED_VERSION }.merge(extra)
  end

  def build(extra = {}) = Open3.capture3(environment(extra), "bash", @script.to_s, @output.to_s)

  def stand_in(name, body)
    tool = @tools.join(name)
    tool.write("#!/usr/bin/env bash\nset -euo pipefail\n#{body}\n")
    tool.chmod(0o755)
  end
end
