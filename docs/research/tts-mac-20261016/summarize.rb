# frozen_string_literal: true
require 'json'
require 'digest'

path = ARGV.fetch(0)
report = JSON.parse(File.read(path))
abort 'Run is unfinished or interrupted' unless report['finished_utc'] && !report['active_attempt']
rows = report.fetch('runs')
artifact_root = File.realpath(report.fetch('output', File.dirname(path)))
expected = report.fetch('engines_requested').product(report.fetch('corpora').keys, (1..report.fetch('iterations_requested')).to_a)
actual = rows.map { |row| row.values_at('engine', 'corpus', 'iteration') }
abort 'Missing, duplicate or substituted attempt identity' unless actual.length == actual.uniq.length && actual.sort == expected.sort
rows.each do |row|
  abort 'Nonterminal attempt' unless %w[passed_full_decode failed timeout].include?(row['status'])
  next unless row['status'] == 'passed_full_decode'
  artifact = File.realpath(row.fetch('file'))
  abort 'Artifact escaped its run directory' unless artifact.start_with?(artifact_root + '/')
  abort 'Artifact hash mismatch' unless Digest::SHA256.file(artifact).hexdigest == row.fetch('sha256')
  abort 'Invalid measured audio duration' unless row.fetch('audio_s') > 0
  if %w[faber edresson kokoro supertonic pocket].include?(row['engine']) && row['first_non_silent_callback_s'] && !row['first_non_silent_pcm_request_s']
    abort 'Incomplete parent callback telemetry; do not substitute file readiness for measured PCM availability'
  end
end
def median(values)
  return nil if values.empty?
  values = values.sort
  (values[(values.size - 1) / 2] + values[values.size / 2]) / 2.0
end
def fmt(value, digits = 2)
  value ? format("%.#{digits}f", value) : '—'
end
summary = report.fetch('engines_requested').map do |engine|
  attempts = rows.select { |row| row['engine'] == engine }
  successful = attempts.select { |row| row['status'] == 'passed_full_decode' }
  short = successful.select { |row| row['corpus'] == 'short' }
  paragraph = successful.select { |row| row['corpus'] == 'paragraph' }
  first_pcm = median(short.filter_map { |row| row['first_non_silent_pcm_request_s'] })
  first_available = median(short.map { |row| row['first_non_silent_pcm_request_s'] || row['request_file_ready_s'] })
  rtf = median(paragraph.filter_map { |row| row['rtf_request'] })
  short_rtf = median(short.filter_map { |row| row['rtf_request'] })
  # An interpretive rubric across every attempt, not a voice-quality metric.
  # Incomplete work earns no throughput points; this is a scoring rule, not a
  # fabricated zero-speed measurement. Actual early PCM still earns start points.
  throughput_points = attempts.sum do |row|
    row['status'] == 'passed_full_decode' ? [1.0, 1.0 / row.fetch('rtf_request')].min : 0.0
  end / attempts.length
  start_points = attempts.sum do |row|
    available = row['first_non_silent_pcm_request_s'] || (row['status'] == 'passed_full_decode' && row['request_file_ready_s'])
    available ? [1.0, 2.0 / available].min : 0.0
  end / attempts.length
  grade = 3.0 * successful.length / attempts.length + 4.0 * throughput_points + 3.0 * start_points
  {
    engine: engine, attempts: attempts.length, passed: successful.length,
    timeouts: attempts.count { |row| row['status'] == 'timeout' },
    failures: attempts.count { |row| row['status'] == 'failed' },
    short_first_non_silent_pcm_s: first_pcm,
    short_first_available_audio_s: first_available,
    first_available_kind: %w[edge qwen06 qwen17].include?(engine) ? 'complete file; streaming not measured' : 'non-silent PCM available; not audible playback',
    short_complete_file_s: median(short.filter_map { |row| row['request_file_ready_s'] }),
    short_rtf_request: short_rtf,
    short_realtime_multiple: short_rtf && 1.0 / short_rtf,
    short_characters_per_request_s: median(short.filter_map { |row| row['characters_per_request_s'] }),
    native_model_load_s: median(successful.filter_map { |row| row['load_s'] }),
    short_native_rtf: median(short.filter_map { |row| row['rtf'] }),
    short_complete_file_range_s: short.filter_map { |row| row['request_file_ready_s'] }.minmax,
    paragraph_complete_file_s: median(paragraph.filter_map { |row| row['request_file_ready_s'] }),
    paragraph_complete_file_range_s: paragraph.filter_map { |row| row['request_file_ready_s'] }.minmax,
    paragraph_completed: paragraph.length,
    short_completed: short.length,
    paragraph_rtf_request: rtf,
    paragraph_characters_per_request_s: median(paragraph.filter_map { |row| row['characters_per_request_s'] }),
    paragraph_native_generation_s: median(paragraph.filter_map { |row| row['synthesis_s'] }),
    short_native_first_pcm_s: median(short.filter_map { |row| row['first_non_silent_callback_s'] }),
    peak_measured_child_rss_mib: successful.filter_map { |row| row['peak_rss_bytes'] }.max&./(1024.0 * 1024),
    technical_path_score: grade&.round(1)
  }
end
output = { source_report: path, created_utc: report['created_utc'],
           rubric: 'Across all attempts: 3*validated_success_fraction + 4*mean(throughput_points) + 3*mean(start_points). A validated attempt earns min(1,1/request_RTF) throughput points; incomplete work earns no throughput points, without inventing a speed measurement. Observed non-silent PCM or a completed file earns min(1,2/first_available_seconds) start points; unavailable output earns no start points. Interpretive execution-path score, not voice quality or mobile acceptance; not pre-registered.',
           verified_artifacts: rows.count { |row| row['status'] == 'passed_full_decode' },
           results: summary }
File.write(File.join(File.dirname(path), 'summary.json'), JSON.pretty_generate(output) + "\n")
puts '| Candidate | Passed | First audio, short (s) | Paragraph file (s) | Request RTF | Chars/s | Child RSS MiB | Timeout | Failure | Technical score /10 |'
puts '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
summary.each do |row|
  puts "| #{row[:engine]} | #{row[:passed]}/#{row[:attempts]} | #{fmt(row[:short_first_available_audio_s])} | #{fmt(row[:paragraph_complete_file_s])} | #{fmt(row[:paragraph_rtf_request], 3)} | #{fmt(row[:paragraph_characters_per_request_s])} | #{fmt(row[:peak_measured_child_rss_mib], 0)} | #{row[:timeouts]} | #{row[:failures]} | #{fmt(row[:technical_path_score], 1)} |"
end
puts "Verified #{output[:verified_artifacts]} successful artifact hashes; #{rows.length} terminal, unique attempts."
