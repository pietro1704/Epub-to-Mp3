# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# Post-merge validation found two container-build defects that no host test
# exercised: the root Dockerfile could not clone sonic (no git) and located the
# eSpeak data with the old Cargo build-output layout, and the Rails image
# regression truncated header values that contain ": ". Run the real pieces.
class HfContainerInputsTest < Minitest::Test
  REPOSITORY = File.expand_path('..', __dir__)
  DOCKERFILE = File.read(File.join(REPOSITORY, 'Dockerfile'))
  IMAGE_REGRESSION = File.join(REPOSITORY, 'ruby_app/rails_gateway/bin/image-regression')

  def setup
    @root = Dir.mktmpdir('hf container inputs ')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_server_builder_can_clone_fetched_sources
    stage = DOCKERFILE[/^FROM rust:.* AS server-builder.*?(?=^FROM )/m]
    refute_nil stage, 'Expected the server-builder stage'
    installed = stage[/apt-get install.*?rm -rf/m].to_s.scan(/^\s+([a-z0-9][a-z0-9.+-]*)(?: \\)?$/).flatten
    %w[git ca-certificates].each { |package| assert_includes installed, package, "#{package} is needed by build scripts that fetch sources" }
  end

  def test_espeak_data_is_found_under_both_cargo_build_output_layouts
    pattern = DOCKERFILE[/find target\/release\/build -type d -path '([^']+)'/, 1]
    refute_nil pattern, 'Expected the espeak data lookup in the Dockerfile'
    legacy = data_directory('espeak-rs-sys-c191fb94e01774d6')
    hashed = data_directory('espeak-rs-sys/69ff7e289cfe9511')
    data_directory('espeak-rs/other')

    found = find_paths(pattern)
    assert_includes found, legacy
    assert_includes found, hashed
    assert_equal 2, found.length, 'Only the espeak-rs-sys build outputs may match'
  end

  def test_header_helper_keeps_values_that_contain_a_colon_and_space
    helper = File.read(IMAGE_REGRESSION)[/^header\(\) \{\n.*?^\}\n/m]
    refute_nil helper, 'Expected the header helper in bin/image-regression'
    csp = "default-src 'self'; img-src 'self' data: blob:; frame-ancestors 'self' https://huggingface.co"
    bin = File.join(@root, 'bin')
    FileUtils.mkdir_p(bin)
    response = File.join(@root, 'response')
    File.binwrite(response, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Security-Policy: #{csp}\r\n\r\n")
    File.write(File.join(bin, 'curl'), "#!/bin/sh\ncat '#{response}'\n")
    File.chmod(0o755, File.join(bin, 'curl'))
    script = "#{helper}\nheader http://127.0.0.1/ content-security-policy\nheader http://127.0.0.1/ content-type\nheader http://127.0.0.1/ missing\n"
    output, status = Open3.capture2e({ 'PATH' => "#{bin}:/usr/bin:/bin" }, 'bash', '-c', script)
    assert status.success?, output
    assert_equal [csp, 'text/html; charset=utf-8', ''], output.split("\n", -1).first(3)
  end

  private

  def data_directory(package)
    directory = File.join(@root, 'target/release/build', package, 'out/share/espeak-ng-data')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'phontab'), 'x')
    directory
  end

  def find_paths(pattern)
    output, status = Open3.capture2e('find', 'target/release/build', '-type', 'd', '-path', pattern, chdir: @root)
    assert status.success?, output
    output.split("\n").map { |relative| File.join(@root, relative) }
  end
end
