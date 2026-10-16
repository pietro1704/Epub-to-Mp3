require 'minitest/autorun'
require 'tmpdir'
require_relative 'package_linux_onnxruntime'

class PackageLinuxOnnxruntimeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('owned ELF package with spaces ')
    @runtime = File.join(@root, 'selected runtime')
    @package = File.join(@root, 'package bin')
    FileUtils.mkdir_p([@runtime, @package])
    @library = File.join(@runtime, 'libonnxruntime.so.1.24.4')
    File.write(File.join(@root, 'runtime.c'), 'int fixture_answer(void) { return 42; }')
    compile_library(@library, 'libonnxruntime.so.1')
    File.symlink(File.basename(@library), File.join(@runtime, 'libonnxruntime.so'))
    @executable = File.join(@package, 'fixture-cli')
    source = File.join(@root, 'cli.c')
    File.write(source, 'extern int fixture_answer(void); int main(void) { return fixture_answer() == 42 ? 0 : 1; }')
    command!('cc', source, '-L', @runtime, '-lonnxruntime', '-o', @executable)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def command!(*arguments)
    text, status = Open3.capture2e(*arguments)
    assert status.success?, "Fixture command failed: #{arguments.inspect}: #{text}"
    text
  end

  def compile_library(path, soname)
    command!('cc', '-shared', '-fPIC', File.join(@root, 'runtime.c'), "-Wl,-soname,#{soname}", '-o', path)
  end

  def package!
    PackageLinuxOnnxruntime.copy!(executable: @executable, directory: @package, runtime_directory: @runtime)
  end

  def test_selected_runtime_is_packaged_under_needed_soname_and_loads_without_the_source
    expected = Digest::SHA256.file(@library).hexdigest
    packaged = package!
    assert_equal File.join(@package, 'libonnxruntime.so.1'), packaged
    refute File.symlink?(packaged)
    assert_equal expected, Digest::SHA256.file(packaged).hexdigest
    FileUtils.remove_entry(@runtime)
    output, status = Open3.capture2e({'LD_LIBRARY_PATH' => @package, 'LD_PRELOAD' => nil}, @executable)
    assert status.success?, "The relocated package could not load its own dependency: #{output}"
  end

  def test_missing_selected_runtime_fails_instead_of_searching_the_host
    File.unlink(@library)
    error = assert_raises(PackageLinuxOnnxruntime::Failure) { package! }
    assert_includes error.message, 'Selected ONNX Runtime is missing'
    refute File.exist?(File.join(@package, 'libonnxruntime.so.1'))
  end

  def test_wrong_soname_is_rejected_before_copying
    compile_library(@library, 'libonnxruntime.so.2')
    error = assert_raises(PackageLinuxOnnxruntime::Failure) { package! }
    assert_includes error.message, 'SONAME differs'
    refute File.exist?(File.join(@package, 'libonnxruntime.so.1'))
  end

  def test_mismatched_elf_machine_is_rejected_before_copying
    # Change only the real ELF machine metadata; no foreign code is executed.
    File.open(@library, 'r+b') do |file|
      file.seek(18)
      file.write([183].pack('v')) # AArch64, unlike this Ubuntu x86_64 fixture.
    end
    error = assert_raises(PackageLinuxOnnxruntime::Failure) { package! }
    assert_includes error.message, 'ELF architecture differs'
    refute File.exist?(File.join(@package, 'libonnxruntime.so.1'))
  end

  def test_conflicting_linker_and_soname_files_are_rejected
    other = File.join(@runtime, 'libonnxruntime.so.1')
    FileUtils.cp(@library, other)
    error = assert_raises(PackageLinuxOnnxruntime::Failure) { package! }
    assert_includes error.message, 'identify different files'
    refute File.exist?(File.join(@package, 'libonnxruntime.so.1'))
  end

  def test_invalid_elf_inspection_is_fatal
    File.binwrite(@executable, 'not an ELF executable')
    error = assert_raises(PackageLinuxOnnxruntime::Failure) { package! }
    assert_includes error.message, 'Cannot inspect ELF dependencies'
  end

  def test_executable_without_an_ort_dependency_requires_no_runtime_payload
    source = File.join(@root, 'no-ort.c')
    File.write(source, 'int main(void) { return 0; }')
    command!('cc', source, '-o', @executable)
    FileUtils.remove_entry(@runtime)
    assert_nil package!
    assert_empty Dir.glob(File.join(@package, 'libonnxruntime*'))
  end
end
