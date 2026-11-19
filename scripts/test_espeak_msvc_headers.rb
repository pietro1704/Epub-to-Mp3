# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# The vendored eSpeak compat shims call __has_include_next, which MSVC does not
# define. Older MSVC toolsets read the unknown macro as 0 in an #if, so the
# shims fell through to their own declarations or the _WIN32 branch. Toolset
# 19.52 rejects it (C7780 "function-like macro '__has_include_next' is not
# defined", then C1017), which broke the Windows package build on a cold cargo
# cache. Reproduce that with a real preprocessor: rename the token so that it is
# undefined, define the Windows environment, and preprocess every shim.
class EspeakMsvcHeadersTest < Minitest::Test
  COMPAT = File.expand_path('../native/vendor/espeak-rs-sys/espeak-ng/src/include/compat', __dir__)
  SHIMS = %w[getopt.h unistd.h endian.h].freeze
  ABSENT = '__espeak_absent_has_include_next'
  COMPILER = %w[cc gcc clang].find { |name| system(name, '--version', out: File::NULL, err: File::NULL) }

  def setup
    skip 'No C preprocessor available' unless COMPILER
    @root = Dir.mktmpdir('espeak compat ')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def test_every_shim_preprocesses_where_has_include_next_is_undefined
    compat = File.join(@root, 'compat')
    FileUtils.mkdir_p(compat)
    SHIMS.each do |name|
      File.write(File.join(compat, name), File.read(File.join(COMPAT, name)).gsub('__has_include_next', ABSENT))
    end
    windows = %w[-U__APPLE__ -U__linux__ -U__unix__ -D_WIN32 -DBYTE_ORDER=1234 -DLITTLE_ENDIAN=1234
                 -DBIG_ENDIAN=4321 -DPDP_ENDIAN=3412]
    SHIMS.each do |name|
      output, status = preprocess(name, "-I#{compat}", *windows)
      assert status.success?, "#{name} must not use #{ABSENT} unguarded:\n#{output.lines.first(4).join}"
    end
    getopt, = preprocess('getopt.h', "-I#{compat}", *windows)
    assert_includes getopt, 'getopt_long', 'Without the system header the getopt shim must declare its own'
  end

  def test_every_shim_still_preprocesses_with_the_real_compiler
    SHIMS.each do |name|
      output, status = preprocess(name, "-I#{COMPAT}")
      assert status.success?, "#{name} failed with the real preprocessor:\n#{output.lines.first(4).join}"
    end
  end

  private

  def preprocess(header, *flags)
    source = File.join(@root, "#{header}.c")
    File.write(source, "#include <#{header}>\nint espeak_marker;\n")
    Open3.capture2e(COMPILER, '-E', '-P', '-x', 'c', *flags, source)
  end
end
