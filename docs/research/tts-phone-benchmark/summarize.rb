# frozen_string_literal: true
require 'json'
require 'digest'
root = File.expand_path('../../..', __dir__)
out = File.join(root, '.reports/tts-six/20261014')
inventory = JSON.parse(File.read(File.join(out, 'model-inventory.json')))
median = ->(values) { sorted = values.sort; n = sorted.length; n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 }
reports = %w[edresson faber kokoro supertonic pocket edge].map do |engine|
  report = JSON.parse(File.read(File.join(out, engine, 'report.json')))
  abort "Wrong engine #{engine}" unless report['engine'] == engine
  if report['status'] == 'passed'
    abort "Incomplete runs #{engine}" unless report['runs'].length == 6 && report['runs'].all? { |r| r['status'] == 'passed_full_decode' && r['audio_duration_seconds'] > 0 }
  end
  model = inventory.find { |entry| entry['engine'] == engine }
  result = { engine: engine, status: report['status'], error: report['error'], runtime: report['runtime'], voice: report['voice'], load_seconds: report['load_seconds'], peak_rss_mib: report['peak_rss_bytes'] / 1048576.0, installed_model_mib: model && model['installed_bytes'] / 1048576.0 }
  if engine == 'pocket' && model
    unused = model['files'].select { |file| %w[mimi_encoder_int8.onnx text_conditioner_int8.onnx].include?(file['path']) }.sum { |file| file['bytes'] }
    result[:required_runtime_mib] = (model['installed_bytes'] - unused) / 1048576.0
  end
  result[:corpora] = report['runs'].group_by { |run| run['corpus'] }.transform_values do |runs|
    runs.each { |run| file = File.join(out, engine, run['file']); abort "Missing audio #{file}" unless File.file?(file); run['sha256'] = Digest::SHA256.file(file).hexdigest }
    { measured_runs: runs.length, median_file_ready_seconds: median.call(runs.map { |r| r['file_ready_seconds'] }), median_audio_duration_seconds: median.call(runs.map { |r| r['audio_duration_seconds'] }), median_rtf: median.call(runs.map { |r| r['rtf_file_ready'] }), median_first_pcm_seconds: runs.all? { |r| r['first_pcm_callback_seconds'].is_a?(Numeric) } ? median.call(runs.map { |r| r['first_pcm_callback_seconds'] }) : nil, chars_per_second: median.call(runs.map { |r| r['characters'] / r['file_ready_seconds'] }) }
  end
  File.write(File.join(out, engine, 'report.json'), JSON.pretty_generate(report) + "\n")
  result
end
texts = reports.select { |r| r[:status] == 'passed' }.map { |r| JSON.parse(File.read(File.join(out, r[:engine], 'report.json')))['runs'].map { |run| [run['corpus'], run['text']] }.uniq }
abort 'Corpus mismatch across successful candidates' unless texts.uniq.length == 1
summary = { date: '2026-10-14', device: 'iPhone 16e', synthetic_fixture_language: 'pt-BR', successful_candidates: reports.count { |r| r[:status] == 'passed' }, expected_candidates: 6, results: reports, limitations: ['Three runs per input; insufficient for reliable p95', 'Two fixed synthetic Portuguese inputs, not whole books or English validation', 'No blind quality score, ASR word-error rate, thermal or battery measurement', 'First PCM callback is not first audible playback; Edge callback was not measured; Pocket prepends 250 ms of silence inside its first callback', 'Fixed engine order; no randomized thermal or network control', 'Process peak RSS includes validation/frameworks, excludes cloud inference; final Pocket/Edge binary additionally links their native adapters', 'Native models output WAV; Edge outputs MP3. Export formats differ', 'Fresh process per engine but OS page cache is not cold', 'Isolated native harness; not end-to-end production conversion', 'Edresson logged skipped nasal phoneme U+0303', 'Edge sixth attempt hit the configured 45-second deadline; two successful paragraph runs do not establish reliable performance'] }
cleanup = File.join(out, 'host-cleanup.json')
summary[:host_cleanup] = JSON.parse(File.read(cleanup)) if File.file?(cleanup)
File.write(File.join(out, 'summary.json'), JSON.pretty_generate(summary) + "\n")
puts JSON.pretty_generate(summary)
