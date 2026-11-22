#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class VerifyAndroidReleaseSignatureTest < Minitest::Test
  OFFICIAL_FINGERPRINT = '5dc8d7437e5b64ae2939851e2994a7e9ac80d5ed3558104ccb751cf92e100faf'
  SIGNER_LINE = "Signer #1 certificate SHA-256 digest: #{OFFICIAL_FINGERPRINT}"
  VERIFIED_OUTPUT = "Verifies\nNumber of signers: 1\n#{SIGNER_LINE}\n"

  def setup
    @directory = Dir.mktmpdir('android release ')
    @apk = File.join(@directory, 'release candidate.apk')
    @calls = File.join(@directory, 'calls.jsonl')
    @apksigner = File.join(@directory, 'apksigner')
    File.write(@apk, '')
    File.write(@apksigner, <<~RUBY_MOCK)
      #!#{RbConfig.ruby}
      require 'json'
      File.open(ENV.fetch('TEST_APKSIGNER_CALLS'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
      if ARGV.include?('--min-sdk-version')
        print ENV.fetch('TEST_APKSIGNER_API_28_OUTPUT')
        warn ENV['TEST_APKSIGNER_API_28_ERROR'] if ENV.key?('TEST_APKSIGNER_API_28_ERROR')
        exit Integer(ENV.fetch('TEST_APKSIGNER_API_28_EXIT', '0'))
      end
      print ENV.fetch('TEST_APKSIGNER_OUTPUT')
    RUBY_MOCK
    FileUtils.chmod(0o755, @apksigner)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(*arguments, **environment)
    defaults = {
      'PATH' => @directory,
      'TEST_APKSIGNER_CALLS' => @calls,
      'TEST_APKSIGNER_OUTPUT' => VERIFIED_OUTPUT,
      'TEST_APKSIGNER_API_28_OUTPUT' => VERIFIED_OUTPUT
    }
    Open3.capture3(defaults.merge(environment), RbConfig.ruby,
                   File.join(__dir__, 'verify_android_release_signature.rb'), *arguments)
  end

  def test_verifies_the_exact_certificate_for_both_platform_ranges
    output, error, status = invoke(@apk, 'TEST_APKSIGNER_API_28_OUTPUT' =>
      VERIFIED_OUTPUT.sub(OFFICIAL_FINGERPRINT, OFFICIAL_FINGERPRINT.upcase))

    assert status.success?, error
    assert_includes output, OFFICIAL_FINGERPRINT
    assert_equal [
      ['verify', '--verbose', '--print-certs', @apk],
      ['verify', '--verbose', '--print-certs', '--min-sdk-version', '28', '--max-sdk-version', '28', @apk]
    ], File.readlines(@calls).map { |line| JSON.parse(line) }
  end

  def test_rejects_a_different_fingerprint_on_each_platform_range
    wrong = OFFICIAL_FINGERPRINT.sub(/f\z/, '0')
    {
      'TEST_APKSIGNER_OUTPUT' => 'supported Android API levels',
      'TEST_APKSIGNER_API_28_OUTPUT' => 'Android API 28'
    }.each do |variable, api_range|
      _output, error, status = invoke(@apk, variable => VERIFIED_OUTPUT.sub(OFFICIAL_FINGERPRINT, wrong))

      refute status.success?
      assert_includes error, api_range
      assert_includes error, OFFICIAL_FINGERPRINT
      assert_includes error, wrong
    end
  end

  def test_rejects_missing_or_malformed_fingerprints
    ['', "#{SIGNER_LINE}0", SIGNER_LINE.sub(/f\z/, '')].each do |line|
      _output, error, status = invoke(@apk, 'TEST_APKSIGNER_OUTPUT' => "Verifies\nNumber of signers: 1\n#{line}\n")

      refute status.success?
      assert_includes error, 'one signer'
    end
  end

  def test_rejects_multiple_signers_even_when_the_official_certificate_is_present
    second_signer = SIGNER_LINE.sub('#1', '#2')
    [
      VERIFIED_OUTPUT.sub('signers: 1', 'signers: 2'),
      "#{VERIFIED_OUTPUT}#{second_signer}\n"
    ].each do |report|
      _output, error, status = invoke(@apk, 'TEST_APKSIGNER_OUTPUT' => report)

      refute status.success?
      assert_includes error, 'one signer'
    end
  end

  def test_rejects_apksigner_failure_even_with_a_matching_certificate_in_stdout
    _output, error, status = invoke(@apk, 'TEST_APKSIGNER_API_28_EXIT' => '1',
                                     'TEST_APKSIGNER_API_28_ERROR' => 'APK signature did not verify')

    refute status.success?
    assert_includes error, 'Android API 28'
    assert_includes error, 'APK signature did not verify'
  end

  def test_reports_missing_apksigner
    File.delete(@apksigner)
    _output, error, status = invoke(@apk)

    refute status.success?
    assert_includes error, 'apksigner'
    assert_includes error, 'PATH'
  end

  def test_rejects_missing_apk_or_extra_arguments_before_running_apksigner
    [[], [@apk, 'extra']].each do |arguments|
      _output, error, status = invoke(*arguments)

      refute status.success?
      assert_includes error, 'Usage:'
    end

    _output, error, status = invoke("#{@apk}.missing")
    refute status.success?
    assert_includes error, 'APK file not found'
    refute_path_exists @calls
  end
end
