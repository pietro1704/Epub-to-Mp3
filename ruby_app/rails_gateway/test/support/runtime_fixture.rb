require "fileutils"
require "pathname"
require_relative "../../lib/converter_runtime/assembler"

# Publishes the hand-written fixture runtime for tests on machines without a
# Rust toolchain. CONVERTER_RUNTIME=built keeps the real generated tree, which
# is how continuous integration runs the same tests.
module RuntimeFixture
  GATEWAY_ROOT = Pathname(__dir__).join("../..").expand_path
  SOURCE = GATEWAY_ROOT.join("test/fixtures/converter_runtime")
  WORKSPACE = GATEWAY_ROOT.join("tmp/runtime_fixture")
  MANIFEST_PATH = WORKSPACE.join("runtime_manifest.json")
  OUTPUT_ROOT = WORKSPACE.join("runtime")
  # The smallest valid WebAssembly module: magic number and version, no sections.
  EMPTY_WASM_MODULE = "\0asm\x01\0\0\0".b.freeze

  def self.built_runtime? = ENV["CONVERTER_RUNTIME"] == "built"

  def self.publish
    staging = WORKSPACE.join("staging")
    FileUtils.rm_rf(staging)
    FileUtils.mkdir_p(staging)
    FileUtils.cp_r(SOURCE.children, staging)
    FileUtils.cp(GATEWAY_ROOT.join("test/fixtures/reader_contract.json"), staging.join("wasm/reader_contract.json"))
    staging.join("wasm/converter_wasm_bg.wasm").binwrite(EMPTY_WASM_MODULE)
    ConverterRuntime::Assembler.new(
      sources: { "wasm" => staging.join("wasm"), "tts" => staging.join("tts") },
      output_root: OUTPUT_ROOT, manifest_path: MANIFEST_PATH
    ).call
  end
end
