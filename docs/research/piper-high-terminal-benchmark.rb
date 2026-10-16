# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
root = File.expand_path('../..', __dir__)
out = File.join(root, '.reports/piper-high/20261014')
assets = File.join(out, 'downloads')
runtime = Dir.glob(File.join(assets, 'sherpa-onnx-*-osx-x64-shared')).first
abort 'Isolated sherpa runtime is required' unless runtime
binary = File.join(runtime, 'bin/sherpa-onnx-offline-tts')
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another native job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
text = JSON.parse(File.read(File.join(root, '.reports/tts-six/20261014/faber/report.json'))).fetch('runs').first.fetch('text')
File.write(File.join(out, 'text.txt'), text)
report = { hardware: 'Intel Core i5-8259U, 8 GiB, macOS x86_64', runtime: 'sherpa-onnx 1.13.8 prebuilt native CLI, CPU, 2 threads', text: text, scope: 'Fresh native CLI process; command wall includes model loading, synthesis and WAV save. Not an iPhone benchmark.', models: [], runs: [] }
begin
  %w[faber-medium miro-high dii-high].each do |name|
    dir = File.join(assets, 'vits-piper-pt_BR-' + name)
    model = Dir.glob(File.join(dir, '*.onnx')).first
    abort "Model missing #{name}" unless model
    config = JSON.parse(File.read(model + '.json'))
    report[:models] << { name: name, bytes: File.size(model), sha256: Digest::SHA256.file(model).hexdigest, configuration: config.slice('audio', 'language', 'espeak', 'inference'), source: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-#{name}.tar.bz2" }
    3.times do |index|
      output = File.join(out, "#{name}-#{index + 1}.wav")
      log = File.join(out, "#{name}-#{index + 1}.log")
      args = [binary, '--num-threads=2', "--vits-model=#{model}", "--vits-tokens=#{dir}/tokens.txt", "--vits-data-dir=#{dir}/espeak-ng-data", "--output-filename=#{output}", text]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      abort "Synthesis failed: #{log}" unless system('/usr/bin/time', '-l', *args, out: log, err: [:child, :out])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      metadata_file = File.join(out, "#{name}-#{index + 1}-metadata.json")
      abort 'ffprobe failed' unless system('ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=sample_rate,channels', '-of', 'json', output, out: metadata_file)
      metadata = JSON.parse(File.read(metadata_file))
      duration = Float(metadata.fetch('format').fetch('duration'))
      abort 'No positive audio duration' unless duration > 0
      decode_log = File.join(out, "#{name}-#{index + 1}-decode.log")
      abort 'Full audio decode failed' unless system('ffmpeg', '-v', 'info', '-i', output, '-af', 'volumedetect', '-f', 'null', '-', out: File::NULL, err: decode_log)
      peak = File.read(decode_log).match(/max_volume:\s+(-?[\d.]+) dB/)
      abort 'Silent audio' unless peak && Float(peak[1]) > -60
      rss = File.read(log).match(/(\d+)\s+maximum resident set size/)
      report[:runs] << { model: name, iteration: index + 1, file: File.basename(output), command_to_complete_wav_s: elapsed, audio_duration_s: duration, rtf: elapsed / duration, peak_rss_bytes: rss && rss[1].to_i, peak_db: Float(peak[1]), status: 'passed_full_decode', sha256: Digest::SHA256.file(output).hexdigest }
      File.write(File.join(out, 'synthesis-report.json'), JSON.pretty_generate(report) + "\n")
      puts "#{name} #{index + 1}: #{elapsed.round(3)} s, audio=#{duration.round(3)} s"
      STDOUT.flush
    end
  end
ensure
  lease.flock(File::LOCK_UN)
  lease.close
end
