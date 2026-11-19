# frozen_string_literal: true

# Host-only metadata fixtures; synthetic plists do not establish Apple compatibility.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "digest"
require "rbconfig"
require_relative "capture_native_test_metadata"

class CaptureNativeTestMetadataTest < Minitest::Test
  SOURCE = File.expand_path("capture_native_test_metadata.rb", __dir__)
  MODULE = CaptureNativeTestMetadata
  PLIST = NativeTestMetadataPlist
  SECRET = "private-value-never-publish"

  def setup
    @root = File.realpath(Dir.mktmpdir("native-metadata-fixture-"))
    @products = File.join(@root, "Products")
    @app = File.join(@products, "Debug/EpubToMp3.app")
    FileUtils.mkdir_p(@app)
    @version = File.join(@root, "version.txt")
    File.write(@version, "Xcode 16.4\nBuild version 16F6\n")
    @output = File.join(@root, "reports/capture")
    @environment = ENV.to_h
    { "CHECKOUT_SHA" => "a", "TREE_SHA" => "b", "PR_HEAD_SHA" => "c", "EVENT_SHA" => "d", "WORKFLOW_SHA" => "e" }.each do |key, value|
      @environment["INVENTORY_#{key}"] = value * 40
    end
    @environment.merge!("INVENTORY_WORKTREE_STATE" => "dirty", "GITHUB_RUN_ID" => "123", "GITHUB_RUN_ATTEMPT" => "1",
                        "GITHUB_JOB" => "macos-preferences", "EXPECTED_ARCH" => "arm64")
    fake_bin = File.join(@root, "bin")
    FileUtils.mkdir_p(fake_bin)
    %w[gh plutil xcodebuild xcrun python python3].each do |name|
      File.write(File.join(fake_bin, name), "#!/bin/sh\nprintf called > \"$FORBIDDEN_CALL\"\nexit 99\n")
      File.chmod(0o755, File.join(fake_bin, name))
    end
    @environment.merge!("PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}", "FORBIDDEN_CALL" => File.join(@root, "called"))
    @manifest = File.join(@products, "fixture.xctestrun")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def xml(value, indent = 0)
    pad = "\t" * indent
    case value
    when Hash
      return "#{pad}<dict/>\n" if value.empty?

      body = value.sort.map { |key, item| "#{pad}\t<key>#{escape(key)}</key>\n#{xml(item, indent + 1)}" }.join
      "#{pad}<dict>\n#{body}#{pad}</dict>\n"
    when Array
      value.empty? ? "#{pad}<array/>\n" : "#{pad}<array>\n#{value.map { |item| xml(item, indent + 1) }.join}#{pad}</array>\n"
    when String then "#{pad}<string>#{escape(value)}</string>\n"
    when Integer then "#{pad}<integer>#{value}</integer>\n"
    else "#{pad}<#{value}/>\n"
    end
  end

  def escape(text) = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  # plistlib.dumps(value, fmt=FMT_XML) layout.
  def dumps(value, fmt = :xml)
    return PLIST.dump_binary(value) if fmt == :binary

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n#{MODULE::APPLE_DOCTYPE}\n<plist version=\"1.0\">\n#{xml(value)}</plist>\n".b
  end

  def fixture(fmt = :xml)
    value = { "__xctestrun_metadata__" => { "FormatVersion" => 2 }, "TestConfigurations" => [{
      "Name" => SECRET, "TestTargets" => [{
        "BlueprintName" => "EpubToMp3Tests", "IsAppHostedTestBundle" => true,
        "TestHostPath" => "__TESTROOT__/Debug/EpubToMp3.app",
        "TestBundlePath" => "__TESTHOST__/Contents/PlugIns/EpubToMp3Tests.xctest",
        "UITargetAppPath" => @app, "EnvironmentVariables" => { "SECRET_NAME" => SECRET },
        "CommandLineArguments" => [SECRET, @root], "UnknownField" => SECRET
      }]
    }] }
    File.binwrite(@manifest, dumps(value, fmt))
    FileUtils.mkdir_p(File.join(@app, "Contents"))
    File.binwrite(File.join(@app, "Contents/Info.plist"), dumps({
      "CFBundleIdentifier" => "com.example.EpubToMp3", "CFBundleExecutable" => "EpubToMp3",
      "CFBundleSupportedPlatforms" => ["MacOSX"], "DTXcode" => "1640", "PrivateField" => SECRET,
      "LSMinimumSystemVersion" => "12.0", "UnknownPath" => @root
    }, fmt))
  end

  def invoke(products: @products, output: @output, environment: @environment, arguments: nil)
    arguments ||= ["--products", products, "--output", output, "--xcode-version-file", @version]
    stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, SOURCE, *arguments, unsetenv_others: true)
    refute_match(/\.rb:\d+:in |Traceback/, stderr)
    refute_includes(stderr, @root)
    assert_operator(stderr.length, :<, 250)
    refute(File.exist?(File.join(@root, "called")))
    [status.exitstatus, stdout, stderr]
  end

  def receipt(output = @output) = JSON.parse(File.read(File.join(output, "receipt.json")))

  def files_under(directory)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).select { |path| File.file?(File.join(directory, path)) }
       .to_h { |path| [path, File.binread(File.join(directory, path))] }
  end

  def assert_sanitized_capture(fmt, index)
    fixture(fmt)
    before = files_under(@products)
    output = File.join(@root, "capture-#{index}")
    status, _stdout, stderr = invoke(output: output)
    assert_equal(0, status, stderr)
    result = receipt(output)
    assert_equal("captured", result["capture_state"])
    assert_equal("unverified", result["runtime_eligibility"])
    assert_equal("a" * 40, result["source"]["checkout_sha"])
    assert_equal("c" * 40, result["source"]["pr_head_sha"])
    assert_equal("dirty", result["source"]["worktree_state"])
    record = result["manifests"][0]
    sanitized = File.binread(File.join(output, record["sanitized_file"]))
    refute_equal(record["original_sha256"], record["sanitized_sha256"])
    assert_equal(Digest::SHA256.hexdigest(File.binread(@manifest)), record["original_sha256"])
    assert_equal(Digest::SHA256.hexdigest(sanitized), record["sanitized_sha256"])
    target = PLIST.load(sanitized)["TestConfigurations"][0]["TestTargets"][0]
    assert_same(true, target["IsAppHostedTestBundle"])
    refute(target.key?("UITargetAppPath"))
    assert_equal("Debug/EpubToMp3.app", record["path_sidecar"][0]["products_relative"])
    assert_equal("string", record["path_sidecar"][0]["observed_type"])
    combined = JSON.generate(result) + PLIST.load(sanitized).inspect
    [SECRET, "SECRET_NAME", "CommandLineArguments", "EnvironmentVariables", @root].each { |forbidden| refute_includes(combined, forbidden) }
    assert_equal(before, files_under(@products))
    [result, sanitized]
  end

  # pytest: test_actual_cli_xml_and_binary_sanitize_without_input_mutation[FMT_XML]
  def test_actual_cli_xml_sanitizes_without_input_mutation
    result, sanitized = assert_sanitized_capture(:xml, 0)
    expected = { "__xctestrun_metadata__" => { "FormatVersion" => 2 }, "TestConfigurations" => [{ "TestTargets" => [{
      "BlueprintName" => "EpubToMp3Tests", "IsAppHostedTestBundle" => true,
      "TestBundlePath" => "__TESTHOST__/Contents/PlugIns/EpubToMp3Tests.xctest", "TestHostPath" => "__TESTROOT__/Debug/EpubToMp3.app"
    }] }] }
    assert_equal(PLIST.dump_binary(expected), sanitized)
    assert_equal(5, result["manifests"][0]["redacted_fields"])
    assert_equal([{ "field" => ["TestConfigurations", 0, "TestTargets", 0, "UITargetAppPath"], "observed_type" => "string",
                    "original_form" => "absolute_products", "products_relative" => "Debug/EpubToMp3.app" }],
                 result["manifests"][0]["path_sidecar"])
    assert_equal([{ "allowed_info" => { "CFBundleExecutable" => "EpubToMp3", "CFBundleIdentifier" => "com.example.EpubToMp3",
                                        "CFBundleSupportedPlatforms" => ["MacOSX"], "DTXcode" => "1640", "LSMinimumSystemVersion" => "12.0" },
                    "original_sha256" => Digest::SHA256.hexdigest(File.binread(File.join(@app, "Contents/Info.plist"))),
                    "products_relative" => "Debug/EpubToMp3.app/Contents/Info.plist" }], result["bundles"])
    assert_equal({ "build" => "16F6", "version" => "16.4" }, result["xcode"])
  end

  # pytest: test_actual_cli_xml_and_binary_sanitize_without_input_mutation[FMT_BINARY]
  def test_actual_cli_binary_sanitizes_without_input_mutation
    assert_sanitized_capture(:binary, 1)
  end

  def test_receipt_json_matches_python_sorted_indent_two_layout
    fixture
    assert_equal(0, invoke.first)
    text = File.read(File.join(@output, "receipt.json"))
    assert_equal(PythonJson.dump(JSON.parse(text), indent: 2, sort_keys: true), text)
    assert(text.start_with?("{\n  \"bundles\": [\n    {\n      \"allowed_info\": {\n"))
    refute(text.end_with?("\n"))
    assert_equal("0600", format("%04o", File.stat(File.join(@output, "receipt.json")).mode & 0o777))
  end

  # pytest: test_missing_products_or_manifest_is_factual_and_never_fabricates_a_manifest (existing products)
  def test_existing_products_without_manifest_is_factual
    assert_missing_manifest(@products, File.join(@root, "missing-report-0"))
  end

  # pytest: test_missing_products_or_manifest_is_factual_and_never_fabricates_a_manifest (missing products)
  def test_missing_products_is_factual_and_never_fabricates_a_manifest
    assert_missing_manifest(File.join(@root, "missing"), File.join(@root, "missing-report-1"))
  end

  def assert_missing_manifest(products, output)
    assert_equal(0, invoke(products: products, output: output).first)
    result = receipt(output)
    assert_equal("missing_manifest", result["capture_state"])
    assert_equal("unverified", result["runtime_eligibility"])
    assert_equal([], result["manifests"])
    assert_equal([], Dir.glob(File.join(output, "*.plist")))
  end

  def assert_bad_xml(declaration, index)
    data = dumps({ "TestConfigurations" => [] }).sub(MODULE::APPLE_DOCTYPE, declaration.b)
    File.binwrite(@manifest, data)
    output = File.join(@root, "bad-xml-#{index}")
    status, _stdout, stderr = invoke(output: output)
    assert_equal(2, status)
    assert_equal("#{MODULE::BLOCKED_MESSAGE}\n", stderr)
    assert_equal("xml_declarations_not_supported", receipt(output)["blocked_reason"])
  end

  # pytest: test_entities_internal_subsets_and_nonstandard_doctypes_are_rejected (3 declarations)
  def test_internal_entity_subset_is_rejected
    assert_bad_xml('<!DOCTYPE plist [<!ENTITY leak "private-value-never-publish">]>', 0)
  end

  def test_external_system_doctype_is_rejected
    assert_bad_xml('<!DOCTYPE plist SYSTEM "https://example.invalid/private.dtd">', 1)
  end

  def test_entity_after_standard_doctype_is_rejected
    assert_bad_xml("#{MODULE::APPLE_DOCTYPE}<!ENTITY leak \"private\">", 2)
  end

  def outside_secret
    File.join(@root, "outside-secret").tap { |path| File.binwrite(path, "outside-preserved") }
  end

  # pytest: test_traversal_external_references_and_symlink_inputs_cannot_escape (4 cases)
  def test_testroot_traversal_reference_cannot_escape
    outside = outside_secret
    File.binwrite(@manifest, dumps({ "EpubToMp3Tests" => { "TestHostPath" => "__TESTROOT__/../outside-secret" } }))
    assert_equal(2, invoke(output: File.join(@root, "escape-0")).first)
    assert_equal("path_escape", receipt(File.join(@root, "escape-0"))["blocked_reason"])
    assert_equal("outside-preserved", File.binread(outside))
  end

  def test_absolute_external_reference_cannot_escape
    outside = outside_secret
    File.binwrite(@manifest, dumps({ "EpubToMp3Tests" => { "TestHostPath" => outside } }))
    assert_equal(2, invoke(output: File.join(@root, "escape-1")).first)
    assert_equal("absolute_reference_outside_products", receipt(File.join(@root, "escape-1"))["blocked_reason"])
    assert_equal("outside-preserved", File.binread(outside))
  end

  def test_symlinked_manifest_leaf_cannot_escape
    outside = outside_secret
    File.symlink(outside, @manifest)
    assert_equal(2, invoke(output: File.join(@root, "symlink-leaf")).first)
    assert_equal("nonregular_or_oversized_input", receipt(File.join(@root, "symlink-leaf"))["blocked_reason"])
    assert_equal("outside-preserved", File.binread(outside))
  end

  def test_symlinked_bundle_cannot_escape
    outside = outside_secret
    File.symlink(File.dirname(outside), File.join(@products, "linked.app"))
    assert_equal(2, invoke(output: File.join(@root, "symlink-bundle")).first)
    assert_equal("symlink_bundle", receipt(File.join(@root, "symlink-bundle"))["blocked_reason"])
    assert_equal("outside-preserved", File.binread(outside))
  end

  # pytest: test_oversized_or_excessive_metadata_is_bounded (2 cases)
  def test_oversized_manifest_is_bounded
    File.binwrite(@manifest, "x" * (MODULE::MAX_MANIFEST_BYTES + 1))
    assert_equal(2, invoke(output: File.join(@root, "oversized")).first)
    assert_equal("nonregular_or_oversized_input", receipt(File.join(@root, "oversized"))["blocked_reason"])
  end

  def test_excessive_manifest_count_is_bounded
    (MODULE::MAX_MANIFESTS + 1).times { |index| File.binwrite(File.join(@products, "#{index}.xctestrun"), "invalid") }
    assert_equal(2, invoke(output: File.join(@root, "too-many")).first)
    assert_equal("manifest_count_exceeded", receipt(File.join(@root, "too-many"))["blocked_reason"])
  end

  # pytest: test_source_identity_validation_and_optional_pr_head_are_explicit (3 cases)
  def test_invalid_checkout_identity_is_blocked_without_echo
    assert_bad_identity("INVENTORY_CHECKOUT_SHA", SECRET, 0, "invalid_source_identity")
  end

  def test_invalid_worktree_state_is_blocked
    assert_bad_identity("INVENTORY_WORKTREE_STATE", "unsafe", 1, "invalid_worktree_state")
  end

  def assert_bad_identity(key, value, index, reason)
    fixture
    output = File.join(@root, "bad-identity-#{index}")
    assert_equal(2, invoke(output: output, environment: @environment.merge(key => value)).first)
    refute_includes(JSON.generate(receipt(output)), SECRET)
    assert_equal(reason, receipt(output)["blocked_reason"])
  end

  def test_empty_pr_head_is_explicit_null
    fixture
    output = File.join(@root, "no-pr")
    environment = @environment.merge("INVENTORY_PR_HEAD_SHA" => "", "INVENTORY_WORKTREE_STATE" => "unknown")
    assert_equal(0, invoke(output: output, environment: environment).first)
    source = receipt(output)["source"]
    assert(source.key?("pr_head_sha"))
    assert_nil(source["pr_head_sha"])
    assert_includes(File.read(File.join(output, "receipt.json")), "\"pr_head_sha\": null,")
  end

  # pytest: test_outputs_reject_input_overlap_symlink_ancestors_and_existing_paths (3 cases)
  def test_output_inside_products_is_rejected
    fixture
    assert_equal(2, invoke(output: File.join(@products, "capture")).first)
    refute(File.exist?(File.join(@products, "capture")))
  end

  def test_output_below_symlink_ancestor_is_rejected
    fixture
    outside = File.join(@root, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@root, "reports-link"))
    status, _stdout, stderr = invoke(output: File.join(@root, "reports-link/capture"))
    assert_equal(2, status)
    assert_equal("#{MODULE::BLOCKED_MESSAGE}\n", stderr)
    assert_empty(Dir.children(outside))
  end

  def test_existing_output_path_is_preserved
    fixture
    FileUtils.mkdir_p(File.dirname(@output))
    File.binwrite(@output, "existing-output")
    assert_equal(2, invoke.first)
    assert_equal("existing-output", File.binread(@output))
  end

  # pytest: test_stable_descriptor_rejects_replacement_during_a_real_read
  def test_stable_descriptor_rejects_replacement_during_a_real_read
    fixture
    descriptor = MODULE.directory(@products)
    original = MODULE.method(:read_chunk)
    products = @products
    manifest = @manifest
    replaced = false
    MODULE.define_singleton_method(:read_chunk) do |io, length|
      result = original.call(io, length)
      unless replaced
        replacement = File.join(products, "replacement")
        File.binwrite(replacement, "replacement-data")
        File.rename(replacement, manifest)
        replaced = true
      end
      result
    end
    error = assert_raises(MODULE::Blocked) { MODULE.read_regular(descriptor, "fixture.xctestrun", MODULE::MAX_MANIFEST_BYTES) }
    assert_match(/input_replaced|input_changed/, error.message)
    assert(replaced)
  ensure
    MODULE.define_singleton_method(:read_chunk, original) if original
    descriptor&.close
  end
end
