# frozen_string_literal: true

# Ruby-only coverage for the plistlib/argparse/json equivalents behind
# capture_native_test_metadata.rb. Expected values follow CPython 3.14 rules.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "rbconfig"
require_relative "capture_native_test_metadata"

class NativeTestMetadataPlistTest < Minitest::Test
  PLIST = NativeTestMetadataPlist
  MODULE = CaptureNativeTestMetadata
  SOURCE = File.expand_path("capture_native_test_metadata.rb", __dir__)

  def xml(body) = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n#{body}\n</plist>\n".b

  def test_binary_writer_matches_plistlib_sorted_layout_byte_for_byte
    # bplist00 | dict(a,b->1,[true,"x"]) | "a" "b" 1 array true "x" | offsets | trailer
    expected = ["62706c6973743030", "d201020304", "5161", "5162", "1001", "a20506", "09", "5178",
                "080d0f11131617", "000000000000", "0101", "0000000000000007", "0000000000000000", "0000000000000019"].join
    assert_equal(expected, PLIST.dump_binary({ "b" => [true, "x"], "a" => 1 }).unpack1("H*"))
  end

  def test_binary_writer_deduplicates_scalars_and_encodes_unicode_as_utf16
    data = PLIST.dump_binary({ "k" => ["é", "é", 300, false, []] })
    assert_equal({ "k" => ["é", "é", 300, false, []] }, PLIST.load(data))
    assert_includes(data, "\x61\x00\xE9".b)
    assert_includes(data, "\x11\x01\x2C".b)
    assert_equal(7, data.byteslice(-24, 8).unpack1("Q>"))
  end

  def test_binary_round_trip_of_large_and_negative_integers
    value = { "a" => [-1, 255, 65_536, (1 << 40), (1 << 63) + 5] }
    assert_equal(value, PLIST.load(PLIST.dump_binary(value)))
  end

  def test_xml_entities_cdata_and_line_endings_follow_expat
    value = PLIST.load(xml("<dict><key>a&amp;b</key><string>x &lt; &#x41;&#66;<![CDATA[<raw>]]>\r\ny</string>" \
                           "<!-- note --><key>n</key><integer> 4_2 </integer><key>h</key><integer>0x1_0</integer>" \
                           "<key>t</key><true/><key>d</key><data>AAE=</data></dict>"))
    assert_equal({ "a&b" => "x < AB<raw>\ny", "n" => 42, "h" => 16, "t" => true, "d" => PLIST::Data.new("\x00\x01".b) }, value)
  end

  def test_nested_element_resets_character_data_like_plistlib
    assert_equal({ "s" => "c" }, PLIST.load(xml("<dict><key>s</key><string>a<b/>c</string></dict>")))
  end

  def test_invalid_xml_and_values_raise_invalid
    [
      "<dict><key>a</key></dict>", "<dict><string>x</string></dict>", "<array><key>a</key></array>",
      "<dict><key>a</key><integer> 0x10</integer></dict>", "<dict><key>a</key><integer>1__0</integer></dict>",
      "<dict><key>a</key><data>A</data></dict>", "<dict><key>a</key><data>AA</data></dict>",
      "<dict><key>a</key><date>2020Z</date></dict>", "<dict><key>a</key><date>2020-02-30Z</date></dict>",
      "<dict><key>a</key><real>1.2.3</real></dict>", "<dict>&undefined;</dict>", "<dict></array>", "<dict>"
    ].each { |body| assert_raises(PLIST::Invalid, body) { PLIST.load(xml(body)) } }
    ["<?xml version=\"1.0\"?><a/><b/>", "plain", "bplist01", "<plist>\x01</plist>", "<?xml version=\"1.0\" encoding=\"EBCDIC\"?><a/>",
     "<plist>\xFF</plist>"].each { |data| assert_raises(PLIST::Invalid, data.inspect) { PLIST.load(data.b) } }
  end

  def test_python_uncaught_handler_failures_stay_uncaught
    assert_raises(PLIST::Crash) { PLIST.load(xml("<key>x</key>")) }
    assert_raises(PLIST::Crash) { PLIST.load(xml("<dict><key>a</key><date>bad</date></dict>")) }
  end

  def test_valid_dates_and_reals_are_accepted
    value = PLIST.load(xml("<dict><key>d</key><date>2024-02-29T23:59:59Z</date><key>r</key><real> -1_0.5e2 </real>" \
                           "<key>i</key><real>Infinity</real></dict>"))
    assert_equal([2024, 2, 29, 23, 59, 59], value["d"].value)
    assert_in_delta(-1050.0, value["r"])
    assert_equal(Float::INFINITY, value["i"])
  end

  def test_binary_reader_rejects_truncated_and_unhashable_input
    data = PLIST.dump_binary({ "a" => "b" })
    assert_raises(PLIST::Invalid) { PLIST.load(data.byteslice(0, 20)) }
    assert_raises(PLIST::Invalid) { PLIST.load(data.byteslice(0, data.bytesize - 1)) }
    # Root dict whose key reference points at an array object.
    unhashable = "bplist00".b + "\xD1\x01\x02\xA0\x51x".b
    offsets = [8, 11, 12].pack("C*")
    trailer = [0, 0, 0, 0, 0, 0, 1, 1].pack("C8") + [3, 0, 8 + 6].pack("Q>3")
    assert_raises(PLIST::Invalid) { PLIST.load(unhashable + offsets + trailer) }
  end

  def test_deeply_nested_binary_hits_python_recursion_limit
    depth = 1200
    objects = Array.new(depth) { |index| index == depth - 1 ? "\xA0".b : [0xA1, index + 1].pack("Cn") }
    body = "bplist00".b
    offsets = objects.map { |object| body.bytesize.tap { body << object } }
    table = body.bytesize
    data = body + offsets.pack("n*") + [0, 0, 0, 0, 0, 0, 2, 2].pack("C8") + [depth, 0, table].pack("Q>3")
    assert_raises(PLIST::Recursion) { PLIST.load(data) }
  end

  def test_json_dumps_matches_python_sort_keys_indent_and_ensure_ascii
    text = PythonJson.dump({ "b" => ["é\u{1F600}\x7f\"\\\n", 1, true, {}, []], "a" => nil }, indent: 2, sort_keys: true)
    assert_equal("{\n  \"a\": null,\n  \"b\": [\n    \"\\u00e9\\ud83d\\ude00\\u007f\\\"\\\\\\n\",\n    1,\n    true,\n    {},\n    []\n  ]\n}", text)
  end

  def test_path_normalization_matches_pathlib_absolute
    assert_equal("/a/b", MODULE.absolute("/a//./b/"))
    assert_equal("#{Dir.pwd}/x", MODULE.absolute("x"))
    assert_equal("path_escape", assert_raises(MODULE::Blocked) { MODULE.absolute("//a") }.message)
    assert_equal("path_escape", assert_raises(MODULE::Blocked) { MODULE.absolute("/a/../b") }.message)
    assert_equal("invalid_path", assert_raises(MODULE::Blocked) { MODULE.absolute("/") }.message)
    assert_equal("invalid_path", assert_raises(MODULE::Blocked) { MODULE.components("a\x7fb") }.message)
    assert_equal(".", MODULE.relative_to("/a/b", "/a/b"))
  end

  def test_unhashable_target_name_maps_to_unreadable_metadata
    assert_raises(TypeError) { MODULE.target_name?(["EpubToMp3Tests"]) }
  end

  def run_cli(*arguments)
    Open3.capture3(RbConfig.ruby, SOURCE, *arguments)
  end

  USAGE = <<~TEXT
    usage: capture_native_test_metadata.rb [-h] --products PRODUCTS
                                           --output OUTPUT
                                           --xcode-version-file XCODE_VERSION_FILE
  TEXT

  def test_argparse_missing_required_arguments
    stdout, stderr, status = run_cli
    assert_equal(2, status.exitstatus)
    assert_empty(stdout)
    assert_equal("#{USAGE}capture_native_test_metadata.rb: error: the following arguments are required: " \
                 "--products, --output, --xcode-version-file\n", stderr)
    _stdout, stderr, = run_cli("--products", "a", "--xcode-version-file", "b")
    assert_equal("#{USAGE}capture_native_test_metadata.rb: error: the following arguments are required: --output\n", stderr)
  end

  def test_argparse_value_and_extra_errors
    _stdout, stderr, status = run_cli("--products")
    assert_equal([2, "#{USAGE}capture_native_test_metadata.rb: error: argument --products: expected one argument\n"], [status.exitstatus, stderr])
    _stdout, stderr, status = run_cli("--prod=a", "--out", "b", "--xcode-version-file", "c", "extra", "-z")
    assert_equal([2, "#{USAGE}capture_native_test_metadata.rb: error: unrecognized arguments: extra -z\n"], [status.exitstatus, stderr])
    _stdout, stderr, = run_cli("-hx")
    assert_equal("#{USAGE}capture_native_test_metadata.rb: error: argument -h/--help: ignored explicit argument 'x'\n", stderr)
  end

  def test_argparse_help
    stdout, stderr, status = run_cli("--products", "a", "--help")
    assert_equal(0, status.exitstatus)
    assert_empty(stderr)
    assert_equal("#{USAGE}\nCapture sanitized existing build metadata; never establish runtime\neligibility.\n\noptions:\n" \
                 "  -h, --help            show this help message and exit\n  --products PRODUCTS\n  --output OUTPUT\n" \
                 "  --xcode-version-file XCODE_VERSION_FILE\n", stdout)
  end

  def test_python_uncaught_parser_failure_exits_one_after_writing_blocked_receipt
    Dir.mktmpdir("native-metadata-crash-") do |temporary|
      root = File.realpath(temporary)
      products = File.join(root, "Products")
      FileUtils.mkdir_p(products)
      File.binwrite(File.join(products, "fixture.xctestrun"), xml("<key>x</key>"))
      File.write(File.join(root, "version.txt"), "Xcode 16.4\nBuild version 16F6\n")
      environment = { "GITHUB_RUN_ID" => "1", "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_JOB" => "macos-preferences",
                      "EXPECTED_ARCH" => "x86_64", "INVENTORY_PR_HEAD_SHA" => "" }
      %w[CHECKOUT_SHA TREE_SHA EVENT_SHA WORKFLOW_SHA].each { |key| environment["INVENTORY_#{key}"] = "f" * 40 }
      _stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, SOURCE, "--products", products, "--output",
                                               File.join(root, "out"), "--xcode-version-file", File.join(root, "version.txt"))
      assert_equal(1, status.exitstatus)
      assert_includes(stderr, "IndexError")
      receipt = JSON.parse(File.read(File.join(root, "out/receipt.json")))
      assert_equal("blocked", receipt["capture_state"])
      refute(receipt.key?("blocked_reason"))
    end
  end
end
