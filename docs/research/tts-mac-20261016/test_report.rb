# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'open3'
require 'rbconfig'

class TtsMacBenchmarkReportTest < Minitest::Test
  SCRIPT = File.expand_path('summarize.rb', __dir__)

  def setup
    @temporary = Dir.mktmpdir('tts-report-contract-')
    @output = File.join(@temporary, 'run')
    FileUtils.mkdir_p(@output)
    # A generated PCM fixture, not speech or a measured model output.
    pcm = Array.new(480, 4096).pack('s<*')
    wave = 'RIFF' + [36 + pcm.bytesize].pack('V') + 'WAVEfmt ' +
           [16, 1, 1, 24000, 48000, 2, 16].pack('VvvVVvv') +
           'data' + [pcm.bytesize].pack('V') + pcm
    @rows = %w[short paragraph].flat_map do |corpus|
      artifact = File.join(@output, "faber-#{corpus}-1.wav")
      File.binwrite(artifact, wave)
      [
        { 'engine' => 'faber', 'corpus' => corpus, 'iteration' => 1,
          'file' => artifact, 'status' => 'passed_full_decode',
          'sha256' => Digest::SHA256.file(artifact).hexdigest, 'audio_s' => 0.02,
          'request_file_ready_s' => 0.005, 'rtf_request' => 0.25,
          'first_non_silent_callback_s' => 0.001,
          'first_non_silent_pcm_request_s' => 0.002, 'peak_rss_bytes' => 1024 },
        { 'engine' => 'qwen06', 'corpus' => corpus, 'iteration' => 1,
          'status' => 'timeout', 'request_wall_s' => 120.2 }
      ]
    end
    @report = { 'created_utc' => '2026-10-16T00:00:00Z', 'finished_utc' => '2026-10-16T00:05:00Z',
                'output' => @output, 'engines_requested' => %w[faber qwen06],
                'iterations_requested' => 1, 'corpora' => { 'short' => {}, 'paragraph' => {} },
                'runs' => @rows }
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def summarize
    path = File.join(@temporary, 'report.json')
    File.write(path, JSON.generate(@report))
    Open3.capture3(RbConfig.ruby, SCRIPT, path)
  end

  def test_validates_archived_artifacts_and_retains_censored_attempts
    output, error, status = summarize
    assert status.success?, error
    assert_includes output, '4 terminal, unique attempts'
    summary = JSON.parse(File.read(File.join(@temporary, 'summary.json')))
    assert_equal 2, summary.fetch('verified_artifacts')
    timed = summary.fetch('results').find { |row| row['engine'] == 'qwen06' }
    assert_equal 2, timed.fetch('timeouts')
    assert_nil timed.fetch('short_rtf_request')
    assert_nil timed.fetch('short_first_available_audio_s')
  end

  def test_rejects_duplicate_attempt_identity
    @rows << @rows.first.dup
    _, error, status = summarize
    refute status.success?
    assert_includes error, 'attempt identity'
  end

  def test_rejects_modified_artifact_bytes
    File.open(@rows.first.fetch('file'), 'ab') { |file| file.write('changed') }
    _, error, status = summarize
    refute status.success?
    assert_includes error, 'hash mismatch'
  end

  def test_rejects_artifacts_outside_owned_run
    outside = File.join(@temporary, 'outside.wav')
    FileUtils.cp(@rows.first.fetch('file'), outside)
    @rows.first['file'] = outside
    _, error, status = summarize
    refute status.success?
    assert_includes error, 'escaped its run directory'
  end

  def test_rejects_cancelled_or_active_snapshot
    @report.delete('finished_utc')
    @report['active_attempt'] = { 'engine' => 'qwen06' }
    _, error, status = summarize
    refute status.success?
    assert_includes error, 'unfinished or interrupted'
  end

  def test_rejects_lost_parent_pcm_telemetry
    @rows.first.delete('first_non_silent_pcm_request_s')
    _, error, status = summarize
    refute status.success?
    assert_includes error, 'Incomplete parent callback telemetry'
  end
end
