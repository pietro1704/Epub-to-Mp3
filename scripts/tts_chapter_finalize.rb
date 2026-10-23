# frozen_string_literal: true

require_relative "tts_book_benchmark"

# Join only ordered, validated, identity-matching MP3 blocks without re-encoding.
module TTSChapterFinalize
  def self.run(directory)
    directory = File.realpath(directory)
    report = JSON.parse(File.read(File.join(directory, "report.json")))
    rows = report.fetch("runs")
    expected = report.fetch("samples").map { |sample| [sample.fetch("id"), sample.fetch("sha256")] }
    actual = rows.map { |row| [row.fetch("sample"), row.fetch("sample_sha256")] }
    raise ArgumentError, "Incomplete, reordered or modified chapter" unless expected == actual && rows.all? { |row| row["status"] == "validated" }
    rows.each do |row|
      path = row.fetch("audio")
      raise ArgumentError, "Audio identity changed" unless TTSBookBenchmark.sha(path) == row.fetch("audio_sha256") && File.dirname(File.realpath(path)) == directory
      raise ArgumentError, "Unsafe artifact name" unless /\A[a-zA-Z0-9_-]+\.mp3\z/.match?(File.basename(path))
    end
    output = File.join(directory, "chapter.mp3")
    raise ArgumentError, "Never overwrite an existing chapter" if File.exist?(output) || File.exist?(output + ".partial")
    playlist = File.join(directory, "chapter-concat.txt")
    File.write(playlist, rows.map { |row| "file '#{File.basename(row.fetch('audio'))}'\n" }.join)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, duration = TTSBookBenchmark.command(["ffmpeg", "-nostdin", "-v", "error", "-f", "concat", "-safe", "1", "-i", playlist,
      "-c:a", "copy", "-f", "mp3", output + ".partial"], directory, output + ".assemble", 60)
    raise "MP3 assembly failed: #{code}" unless code.zero?
    File.open(output + ".partial", "r+") { |file| file.fsync }
    File.rename(output + ".partial", output)
    validated = TTSBookBenchmark.inspect_audio(output, directory, 60)
    result = { "assembly_command_s" => duration, "assembly_and_validation_s" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
               "encoding" => "MP3 stream copy; no second lossy encode", "blocks" => rows.length }.merge(validated)
    File.write(File.join(directory, "chapter-export.json"), JSON.pretty_generate(result) + "\n")
    result
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise ArgumentError, "Usage: COMPLETED_BATCH_DIRECTORY" unless ARGV.length == 1
    puts JSON.generate(TTSChapterFinalize.run(ARGV.first))
  rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError, RuntimeError => error
    warn error.message
    exit 2
  end
end
