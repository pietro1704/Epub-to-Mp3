# frozen_string_literal: true
require "minitest/autorun"
require_relative "tts_gradio_probe"

class GradioEventReaderTest < Minitest::Test
  def test_every_transport_split_preserves_events_and_unicode
    input = "event: heartbeat\ndata: null\n\nevent: complete\ndata: [{\"url\":\"https://demo.hf.space/audio.wav\"},\"Português\"]\n\n".b
    (1...input.bytesize).each do |split|
      events = []
      reader = GradioEventReader.new { |event, payload| events << [event, payload] }
      reader.feed(input.byteslice(0, split))
      reader.feed(input.byteslice(split..))
      assert_equal [["heartbeat", nil], ["complete", [{ "url" => "https://demo.hf.space/audio.wav" }, "Português"]]], events
    end
  end

  def test_progress_events_are_not_audio_completion
    events = []
    reader = GradioEventReader.new { |event, payload| events << [event, payload] }
    reader.feed("event: generating\ndata: [0.5]\n\nevent: error\ndata: \"GPU quota exceeded\"\n\n")
    assert_equal %w[generating error], events.map(&:first)
    refute events.any? { |event, _| event == "complete" }
  end

  def test_crlf_boundaries_survive_single_byte_transport_chunks
    events = []
    reader = GradioEventReader.new { |event, payload| events << [event, payload] }
    "event: complete\r\ndata: [null,\"ok\"]\r\n\r\n".each_byte { |byte| reader.feed(byte.chr) }
    assert_equal [["complete", [nil, "ok"]]], events
  end
end
