# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# Post-merge validation found that bin/image-regression split response headers
# on ": " and printed the second field, so a Content-Security-Policy containing
# "data: blob:" was cut before frame-ancestors and the check reported that
# Hugging Face could not embed the document. Run the real helper.
class HfContainerInputsTest < Minitest::Test
  REPOSITORY = File.expand_path('..', __dir__)
  IMAGE_REGRESSION = File.join(REPOSITORY, 'ruby_app/rails_gateway/bin/image-regression')

  def setup
    @root = Dir.mktmpdir('hf container inputs ')
  end

  def teardown
    FileUtils.remove_entry(@root)
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

  def test_the_image_is_built_from_the_root_dockerfile_of_the_repository
    script = File.read(IMAGE_REGRESSION)
    assert_includes script, 'docker build --tag "$image" "$workspace_root"'
    assert File.file?(File.join(REPOSITORY, 'Dockerfile')), 'The Rails image Dockerfile must be at the repository root'
    refute File.exist?(File.join(REPOSITORY, 'ruby_app/rails_gateway/Dockerfile')), 'There must be a single Dockerfile'
  end
end
