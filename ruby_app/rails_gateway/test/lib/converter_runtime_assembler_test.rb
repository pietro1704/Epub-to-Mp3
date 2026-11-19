require "test_helper"
require "converter_runtime/assembler"

class ConverterRuntimeAssemblerTest < ActiveSupport::TestCase
  setup do
    @workspace = Pathname(Dir.mktmpdir("converter-runtime-assembler-"))
    @wasm = @workspace.join("built/wasm").tap(&:mkpath)
    @wasm.join("converter_wasm.js").write("export default async function init() {}\n")
    @wasm.join("converter_wasm_bg.wasm").binwrite(RuntimeFixture::EMPTY_WASM_MODULE)
    @output_root = @workspace.join("public/runtime")
    @manifest_path = @workspace.join("config/runtime_manifest.json")
  end

  teardown { FileUtils.remove_entry(@workspace) }

  test "publishes the given files un-renamed under the digest of the tree" do
    tts = @workspace.join("built/tts").tap(&:mkpath)
    tts.join("nested").mkpath
    tts.join("nested/piper_phonemize.data").binwrite("data")

    runtime_id = assemble("wasm" => @wasm, "tts" => tts)

    assert_match(/\A[0-9a-f]{64}\z/, runtime_id)
    published = @output_root.join(runtime_id)
    assert_equal %w[tts/nested/piper_phonemize.data wasm/converter_wasm.js wasm/converter_wasm_bg.wasm],
      published.glob("**/*").select(&:file?).map { |file| file.relative_path_from(published).to_s }.sort
    assert_equal RuntimeFixture::EMPTY_WASM_MODULE, published.join("wasm/converter_wasm_bg.wasm").binread
  end

  test "the manifest lets Rails resolve the tree and its files" do
    runtime_id = assemble("wasm" => @wasm)
    tree = ConverterRuntime::Tree.new(manifest_path: @manifest_path, root: @output_root)

    assert_predicate tree, :available?
    assert_equal "/runtime/#{runtime_id}/", tree.base_path
    assert tree.file?("wasm/converter_wasm.js")
    refute tree.file?("wasm/other.js")
    entry = JSON.parse(@manifest_path.read).dig("files", "wasm/converter_wasm_bg.wasm")
    assert_equal({ "sha256" => Digest::SHA256.hexdigest(RuntimeFixture::EMPTY_WASM_MODULE), "bytes" => 8 }, entry)
  end

  test "the id changes with content and is stable for identical content" do
    first = assemble("wasm" => @wasm)
    assert_equal first, assemble("wasm" => @wasm)

    @wasm.join("converter_wasm.js").write("export default async function init() { return 1 }\n")
    second = assemble("wasm" => @wasm)

    refute_equal first, second
    assert_equal [ second ], @output_root.children.map { |entry| entry.basename.to_s }
  end

  test "refuses a tree without the WebAssembly bindings and leaves no manifest" do
    @wasm.join("converter_wasm_bg.wasm").delete

    error = assert_raises(ArgumentError) { assemble("wasm" => @wasm) }

    assert_includes error.message, "wasm/converter_wasm_bg.wasm"
    refute_predicate @manifest_path, :exist?
  end

  test "refuses empty files and missing source directories" do
    @wasm.join("converter_wasm.js").write("")
    assert_raises(ArgumentError) { assemble("wasm" => @wasm) }
    assert_raises(ArgumentError) { assemble("wasm" => @workspace.join("absent")) }
  end

  test "a server without a published runtime announces none" do
    tree = ConverterRuntime::Tree.new(manifest_path: @manifest_path, root: @output_root)

    refute_predicate tree, :available?
    assert_nil tree.base_path
    refute tree.file?("wasm/converter_wasm.js")
  end

  private

  def assemble(sources)
    ConverterRuntime::Assembler.new(sources: sources, output_root: @output_root, manifest_path: @manifest_path).call
  end
end
