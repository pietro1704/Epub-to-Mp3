require 'minitest/autorun'
require 'rbconfig'
require_relative 'verify_cli_faber'

class VerifyCliFaberTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('cli harness fixture with spaces ')
    @sample = File.join(@root, 'sample.epub')
    File.write(@sample, 'owned input fixture')
    @cli = File.join(@root, 'owned CLI')
    @reports = File.join(@root, 'reports')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def executable(body)
    File.write(@cli, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, @cli)
  end

  def runner
    CliFaberVerification.new(cli: @cli, sample: @sample, reports: @reports, temporary_root: @root)
  end

  def test_successful_command_uses_only_the_explicit_executable_and_literal_arguments
    executable('require "json"; puts JSON.generate(ARGV)')
    stdout, stderr, status = runner.cli!('preferences', 'a literal argument with spaces')
    assert status.success?
    assert_empty stderr
    assert_equal ['preferences', 'a literal argument with spaces'], JSON.parse(stdout)
  end

  def test_missing_executable_has_no_runtime_or_path_fallback
    error = assert_raises(CliFaberVerification::Failure) { runner.cli!('preferences', 'show') }
    assert_includes error.message, 'explicitly packaged CLI executable is missing'
    refute File.exist?(File.join(@reports, 'evidence.json'))
  end

  def test_missing_runtime_cannot_count_as_expected_missing_model_or_as_golden_success
    executable(<<~RUBY)
      case ARGV.first
      when 'preferences'
        puts #{JSON.generate(CliFaberVerification::PREFERENCES).dump} if ARGV[1] == 'show'
      when 'models'
        abort 'Model installation must not be reached after a runtime failure' if ARGV[1] == 'install'
        puts "pt_BR-faber-medium\\t63206149 bytes\\tnot installed"
      when 'convert'
        warn 'Piper embedded runtime unavailable: required shared library missing'
        exit 2
      else
        abort 'Unexpected command'
      end
    RUBY
    error = assert_raises(CliFaberVerification::Failure) { runner.run! }
    assert_includes error.message, 'never for a missing runtime'
    refute File.exist?(File.join(@reports, 'evidence.json'))
    assert_empty Dir.glob(File.join(@root, 'cli-faber-owned-*')), 'Failed golden runs must clean only their owned temporary state'
  end

  def test_unexpected_command_failure_is_fatal
    executable("warn 'fixture command failed'; exit 9")
    error = assert_raises(CliFaberVerification::Failure) { runner.cli!('models', 'install', CliFaberVerification::MODEL) }
    assert_includes error.message, 'failed (9)'
  end

  def test_manifest_identity_accepts_the_actual_job_and_rejects_traversal_or_wrong_selection
    output = File.join(@root, 'output')
    FileUtils.mkdir_p(File.join(output, 'cli-fixture'))
    manifest = {
      'jobId' => 'cli-fixture', 'sourceChaptersTotal' => 2,
      'chapters' => [{'sourceIndex' => 0}, {'sourceIndex' => 1}],
      'ttsPreferences' => CliFaberVerification::PREFERENCES,
      'usedSelections' => [CliFaberVerification::PREFERENCES['primary']],
      'ttsPolicyState' => {'consecutive_failures' => 0}
    }
    assert_equal File.join(output, 'cli-fixture'), runner.validate_manifest_identity!(manifest, output)
    [
      {'jobId' => '../outside'},
      {'chapters' => [{'sourceIndex' => 0}, {'sourceIndex' => 0}]},
      {'usedSelections' => [{'engine' => 'edge', 'model_id' => nil, 'voice' => 'unexpected'}]},
      {'fallbackUsed' => true},
      {'ttsPolicyState' => {'consecutive_failures' => 2}}
    ].each do |change|
      assert_raises(CliFaberVerification::Failure) { runner.validate_manifest_identity!(manifest.merge(change), output) }
    end
    File.symlink(File.join(output, 'cli-fixture'), File.join(output, 'linked-job'))
    assert_raises(CliFaberVerification::Failure) do
      runner.validate_manifest_identity!(manifest.merge('jobId' => 'linked-job'), output)
    end
  end

  def test_cleanup_removes_only_the_marked_owned_directory
    FileUtils.mkdir_p(@reports)
    owned = Dir.mktmpdir('cli-faber-owned-', @root)
    File.write(File.join(owned, '.cli-faber-verification-owned'), "cli-faber-v1\n")
    File.write(File.join(owned, 'temporary model.onnx'), 'owned test weight')
    registry = File.join(@reports, 'owned-root.txt')
    File.write(registry, owned)
    CliFaberVerification.cleanup_owned!(reports: @reports, temporary_root: @root)
    refute File.exist?(owned)
    protected_directory = File.join(@root, 'unrelated data')
    FileUtils.mkdir_p(protected_directory)
    File.write(registry, protected_directory)
    assert_raises(CliFaberVerification::Failure) do
      CliFaberVerification.cleanup_owned!(reports: @reports, temporary_root: @root)
    end
    assert File.directory?(protected_directory)
  end

  def test_receipt_requires_typed_faber_identity_and_the_exact_audio_bytes
    audio = File.join(@root, 'completed.mp3')
    File.binwrite(audio, 'owned completed audio')
    receipt = {'version' => 2, 'provider' => nil, 'fallback_used' => false,
      'used_selections' => [CliFaberVerification::PREFERENCES['primary']],
      'request_key' => 'a' * 64, 'size' => File.size(audio),
      'audio_sha256' => Digest::SHA256.file(audio).hexdigest}
    runner.verify_receipt!(receipt, audio)
    runner.verify_receipt!(receipt.merge('provider' => 'piper'), audio)
    [{'version' => 1}, {'provider' => 'edge'}, {'fallback_used' => true},
      {'used_selections' => []}, {'audio_sha256' => 'b' * 64}, {'size' => 0}].each do |change|
      assert_raises(CliFaberVerification::Failure) { runner.verify_receipt!(receipt.merge(change), audio) }
    end
    File.binwrite(audio, 'different audio bytes')
    assert_raises(CliFaberVerification::Failure) { runner.verify_receipt!(receipt, audio) }
  end

  def with_decoder(samples:, exit_code: 0)
    probe = File.join(@root, 'owned ffprobe')
    decoder = File.join(@root, 'owned ffmpeg')
    arguments = File.join(@root, 'decoder arguments.json')
    File.write(probe, "#!#{RbConfig.ruby}\nputs '#{JSON.generate({'streams' => [{'codec_name' => 'mp3', 'sample_rate' => '24000', 'channels' => 1}]})}'\n")
    File.write(decoder, <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.write(#{arguments.dump}, JSON.generate(ARGV))
      exit #{exit_code} unless #{exit_code}.zero?
      File.binwrite(ARGV.last, #{samples.pack('e*').dump})
    RUBY
    [probe, decoder].each { |path| File.chmod(0o755, path) }
    previous = ENV.values_at('FFPROBE', 'FFMPEG')
    ENV['FFPROBE'], ENV['FFMPEG'] = probe, decoder
    yield arguments
  ensure
    ENV['FFPROBE'], ENV['FFMPEG'] = previous if previous
  end

  def test_full_decode_requires_xerror_finite_non_silent_samples_and_propagates_failure
    audio = File.join(@root, 'chapter with spaces.mp3')
    File.write(audio, 'owned encoded fixture')
    with_decoder(samples: [0.0, 0.5, -0.5]) do |arguments|
      evidence = runner.verify_audio!(audio, @root)
      assert_equal 3, evidence['samples']
      assert_equal 0.5, evidence['peak']
      actual = JSON.parse(File.read(arguments))
      assert_includes actual, '-xerror'
      assert_equal audio, actual.fetch(actual.index('-i') + 1)
    end
    [[0.0, 0.0], [], [Float::NAN]].each do |samples|
      with_decoder(samples: samples) do
        assert_raises(CliFaberVerification::Failure) { runner.verify_audio!(audio, @root) }
      end
    end
    with_decoder(samples: [0.5], exit_code: 9) do
      assert_raises(CliFaberVerification::Failure) { runner.verify_audio!(audio, @root) }
    end
  end
end
