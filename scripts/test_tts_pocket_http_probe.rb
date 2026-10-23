# frozen_string_literal: true

require "minitest/autorun"
require_relative "tts_pocket_http_probe"

class PocketWaveArrivalTest < Minitest::Test
  def wave(samples, declared: nil)
    pcm = samples.pack("s<*")
    "RIFF".b + [pcm.bytesize + 36].pack("V") + "WAVEfmt " + [16, 1, 1, 24_000, 48_000, 2, 16].pack("VvvVVvv") + "data" + [declared || pcm.bytesize].pack("V") + pcm
  end

  def test_headers_and_silence_do_not_count_as_non_silent_pcm
    data = wave([0, 0, 100, -100])
    received = +"".b
    probe = PocketWaveArrival.new { |pcm| received << pcm }
    probe.feed(data.byteslice(0, 44), 0.1)
    assert_nil probe.first_pcm
    assert_nil probe.first_signal
    probe.feed(data.byteslice(44, 4), 0.2)
    assert_equal 0.2, probe.first_pcm
    assert_nil probe.first_signal
    probe.feed(data.byteslice(48..), 0.3)
    probe.finish
    assert_equal 0.3, probe.first_signal
    assert_equal [0, 0, 100, -100].pack("s<*"), received
  end

  def test_every_split_position_preserves_pcm_and_parses_incremental_headers
    data = wave([0, 200, -200, 0], declared: 0xffffffff)
    (1...data.bytesize).each do |split|
      received = +"".b
      probe = PocketWaveArrival.new { |pcm| received << pcm }
      probe.feed(data.byteslice(0, split), 0.1)
      probe.feed(data.byteslice(split..), 0.2)
      probe.finish
      assert_equal [0, 200, -200, 0].pack("s<*"), received
      assert_equal 24_000, probe.format.fetch("sample_rate")
    end
  end

  def test_truncated_and_silent_responses_fail
    probe = PocketWaveArrival.new { |_| }
    probe.feed(wave([100], declared: 8), 0.1)
    assert_raises(RuntimeError) { probe.finish }
    silent = PocketWaveArrival.new { |_| }
    silent.feed(wave([0, 0]), 0.1)
    assert_raises(RuntimeError) { silent.finish }
    invalid = PocketWaveArrival.new { |_| }
    assert_raises(RuntimeError) { invalid.feed("not audio at all".b, 0.1) }
  end

  def test_reviewed_pocket_stream_placeholder_does_not_hide_real_truncation
    probe = PocketWaveArrival.new(streaming_size_sentinels: [2_000_000_000]) { |_| }
    probe.feed(wave([100, -100], declared: 2_000_000_000), 0.2)
    probe.finish
    assert_equal 4, probe.pcm_bytes
    assert_equal 0.2, probe.first_signal
    ordinary = PocketWaveArrival.new(streaming_size_sentinels: [2_000_000_000]) { |_| }
    ordinary.feed(wave([100], declared: 10), 0.3)
    assert_raises(RuntimeError) { ordinary.finish }
  end
end
