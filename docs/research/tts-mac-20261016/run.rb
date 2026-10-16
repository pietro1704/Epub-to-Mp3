# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'time'
require 'open3'

root = File.expand_path('../../..', __dir__)
base = File.join(root, '.reports/tts-mac-20261016')
assets = File.join(base, 'assets')
stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
out = File.join(base, stamp)
FileUtils.mkdir_p(base)
Dir.mkdir(out)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
texts = {
  'short' => 'A biblioteca estava silenciosa. "Vamos começar?", perguntou Ana. Às 8h30, ela abriu o livro e leu a primeira página.',
  'paragraph' => 'Na manhã de terça-feira, Ana encontrou um livro antigo na biblioteca. A capa estava gasta, mas as páginas permaneciam legíveis. "Quanto custa?", perguntou ela. O funcionário respondeu: "Vinte e três reais e cinquenta centavos." Ana sorriu, conferiu o relógio às 8h30 e decidiu começar a leitura. No primeiro capítulo, um viajante atravessava a cidade em busca de notícias de sua família. Ele parou diante da estação, observou as pessoas e perguntou qual trem partiria às 14h15. A resposta chegou depressa: plataforma número 3. Mesmo com a chuva e o vento, o viajante continuou seu caminho. Não precisava correr; precisava apenas chegar antes do anoitecer.'
}
texts.select! { |name, _| ENV.fetch('TTS_MAC_CORPORA', texts.keys.join(',')).split(',').include?(name) }
corpus_file = File.join(out, 'corpus.json')
File.write(corpus_file, JSON.pretty_generate(texts) + "\n")
texts.each { |name, text| File.write(File.join(out, name + '.txt'), text) }
python = '/Users/pips/Developer/epubtomp3/.venv/bin/python'
edge = '/Users/pips/Developer/epubtomp3/target/debug/embedded_edge_probe'
llama = File.join(assets, 'llama-b11669/llama-tts')
environment = {
  'PYTHONPATH' => File.join(base, 'packages'),
  'DYLD_LIBRARY_PATH' => File.join(assets, 'sherpa-onnx-v1.13.8-osx-x64-shared/lib'),
  'OMP_NUM_THREADS' => '2', 'OPENBLAS_NUM_THREADS' => '2',
  'VECLIB_MAXIMUM_THREADS' => '2', 'TOKENIZERS_PARALLELISM' => 'false',
  'HF_HUB_OFFLINE' => '1'
}
report = {
  schema: 1, created_utc: Time.now.utc.iso8601, pid: Process.pid,
  hardware: 'Intel Core i5-8259U @ 2.30GHz, 8 GiB RAM, macOS x86_64',
  head: `git -C #{root} rev-parse HEAD`.strip,
  output: out, threads: 2, timeout_per_attempt_s: 120,
  macos: IO.popen(['sw_vers', '-productVersion'], &:read).strip,
  harness_sha256: %w[run.rb worker.py pocket-worker.py].to_h { |name| [name, Digest::SHA256.file(File.join(__dir__, name)).hexdigest] },
  process_state: 'fresh process per attempt; filesystem/OS caches are not purged',
  corpora: texts.transform_values { |t| { text: t, characters: t.length, sha256: Digest::SHA256.hexdigest(t) } },
  limitations: ['Host experiment, not app/mobile/Simulator acceptance', 'No speaker playback or blind quality rating', 'Three attempts do not establish p95', 'Other user workloads remain running', 'Native CPU libraries called through an isolated Python research harness for Sherpa models', 'Qwen CLI outputs a complete WAV, not external streaming; its TTFA is not measured', 'Apple/Edge remote services are excluded from child RSS', 'ASR/text fidelity and energy/thermals are not measured'],
  runs: [], excluded: []
}
report_path = File.join(out, 'report.json')
checkpoint = lambda do
  File.write(report_path + '.partial', JSON.pretty_generate(report) + "\n")
  File.rename(report_path + '.partial', report_path)
end
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job owns the shared lease; benchmark not started.' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
active = nil
stop = lambda do
  if active
    Process.kill('TERM', -active) rescue nil
    sleep 0.15
    Process.kill('KILL', -active) rescue nil
  end
end
Signal.trap('INT') { raise Interrupt }
Signal.trap('TERM') { raise Interrupt }
begin
  engines = ENV.fetch('TTS_MAC_ENGINES', 'apple,edresson,faber,kokoro,supertonic,pocket,edge,qwen06,qwen17').split(',')
  report[:engines_requested] = engines
  report[:iterations_requested] = Integer(ENV.fetch('TTS_MAC_ITERATIONS', '3'))
  checkpoint.call
  File.write(File.join(base, 'latest.json'), JSON.pretty_generate({ report: report_path, pid: Process.pid, started_utc: report[:created_utc] }) + "\n")
  Integer(ENV.fetch('TTS_MAC_ITERATIONS', '3')).times do |index|
    texts.each do |name, text|
      # Alternate direction between blocks to reduce fixed engine-order effects.
      order = (index + (name == 'paragraph' ? 1 : 0)).even? ? engines : engines.reverse
      order.each do |engine|
        prefix = File.join(out, "#{engine}-#{name}-#{index + 1}")
        audio = prefix + (engine == 'edge' ? '.mp3' : '.wav')
        row = { engine: engine, corpus: name, iteration: index + 1, characters: text.length,
                file: audio, status: 'running', first_pcm_request_s: nil, first_non_silent_pcm_request_s: nil }
        row[:host_load_before] = IO.popen(['uptime'], &:read).strip
        env = environment.merge('BENCH_CORPUS' => name, 'BENCH_ITERATION' => (index + 1).to_s)
        argv = case engine
               when 'apple'
                 ['/usr/bin/say', '-v', 'Luciana', '--file-format=WAVE', '--data-format=LEI16@24000', '-f', File.join(out, name + '.txt'), '-o', audio]
               when 'edge'
                 [edge, audio]
               when 'qwen06', 'qwen17'
                 backbone, projector = engine == 'qwen06' ? ['Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf', 'Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf'] : ['Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf', 'mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf']
                 [llama, '-m', File.join(assets, backbone), '-mm', File.join(assets, projector), '--device', 'none', '-ngl', '0', '--no-mmproj-offload', '--tts-lang', 'pt', '--tts-speaker-file', File.join(base, 'reference.wav'), '-t', '2', '-tb', '2', '-c', '4096', '-n', '2048', '--seed', '42', '-f', File.join(out, name + '.txt'), '-o', audio]
               else
                 worker = engine == 'pocket' ? 'pocket-worker.py' : 'worker.py'
                 [python, File.join(__dir__, worker), assets, engine, corpus_file, out]
               end
        row[:argv] = argv
        puts "START #{engine} #{name} #{index + 1}"
        STDOUT.flush
        started = clock.call
        buffer = +''
        timed_out = false
        pipe, writer = IO.pipe
        begin
          File.open(prefix + '.stderr', 'w') do |errors|
            File.open(File.join(out, name + '.txt'), 'r') do |input|
              active = Process.spawn(env, '/usr/bin/time', '-l', *argv, in: input, out: writer, err: errors, pgroup: true)
              report[:active_attempt] = { engine: engine, corpus: name, iteration: index + 1, process_group: active, started_utc: Time.now.utc.iso8601 }
              checkpoint.call
            end
            writer.close
            File.open(prefix + '.stdout', 'w') do |log|
              loop do
                if IO.select([pipe], nil, nil, 0.01)
                  data = pipe.read_nonblock(65536, exception: false)
                  unless data.nil? || data == :wait_readable
                    log.write(data)
                    buffer << data
                    while (line = buffer.slice!(/.*\n/))
                      begin
                        event = JSON.parse(line)
                        case event['event']
                        when 'start'
                          row[:generation_started_after_process_s] = clock.call - started
                        when 'loaded'
                          row[:load_s] = event['load_s']
                        when 'first_audio'
                          row[:first_non_silent_pcm_request_s] ||= clock.call - started
                        when 'result'
                          row.merge!(event.reject { |key, _| key == 'event' }.transform_keys(&:to_sym))
                          row[:first_pcm_request_s] = row[:generation_started_after_process_s] + event['first_pcm_callback_s'] if event['first_pcm_callback_s']
                          row[:request_file_ready_s] = clock.call - started
                        end
                      rescue JSON::ParserError
                        # Native CLI output is retained verbatim, never treated as telemetry.
                      end
                    end
                  end
                end
                if engine == 'apple' && row[:first_non_silent_pcm_request_s].nil? && File.file?(audio) && File.size(audio) > 64
                  bytes = File.binread(audio)
                  # Parse RIFF chunks, ignoring placeholder lengths in a growing data chunk.
                  pos = 12
                  while pos + 8 <= bytes.bytesize
                    id = bytes.byteslice(pos, 4)
                    size = bytes.byteslice(pos + 4, 4).unpack1('V')
                    if id == 'data'
                      pcm = bytes.byteslice(pos + 8..)
                      pcm = pcm.byteslice(0, pcm.bytesize & ~1)
                      if pcm.unpack('s<*').any? { |sample| sample.abs > 33 }
                        row[:first_non_silent_pcm_request_s] = clock.call - started
                        row[:first_pcm_request_s] = row[:first_non_silent_pcm_request_s]
                      end
                      break
                    end
                    pos += 8 + size + (size & 1)
                  end
                end
                finished = Process.waitpid2(active, Process::WNOHANG)
                if finished
                  row[:exit_code] = finished[1].exitstatus
                  row[:signal] = finished[1].termsig
                  active = nil
                  break
                end
                if clock.call - started >= 120
                  timed_out = true
                  stop.call
                  Process.waitpid(active) rescue nil
                  active = nil
                  break
                end
              end
              # Flush tail telemetry after the child exits, without waiting for another child.
              tail = pipe.read
              log.write(tail)
              (buffer + tail).lines.each do |line|
                event = JSON.parse(line) rescue nil
                next unless event.is_a?(Hash) && event['event'] == 'result'
                row.merge!(event.reject { |key, _| key == 'event' }.transform_keys(&:to_sym))
                row[:first_pcm_request_s] = row[:generation_started_after_process_s] + event['first_pcm_callback_s'] if event['first_pcm_callback_s'] && row[:generation_started_after_process_s]
              end
            end
          end
          row[:request_wall_s] = clock.call - started
          row[:host_load_after] = IO.popen(['uptime'], &:read).strip
          row[:status] = timed_out ? 'timeout' : (row[:exit_code] == 0 ? 'completed_unvalidated' : 'failed')
          rss = File.read(prefix + '.stderr').match(/(\d+)\s+maximum resident set size/)
          row[:peak_rss_bytes] = rss[1].to_i if rss
          if row[:status] == 'completed_unvalidated'
            row[:request_file_ready_s] ||= row[:request_wall_s]
            metadata, result = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=sample_rate,channels', '-of', 'json', audio)
            raise 'ffprobe rejected generated audio' unless result.success?
            row[:metadata] = JSON.parse(metadata)
            row[:audio_s] = Float(row[:metadata].fetch('format').fetch('duration'))
            raise 'No positive audio duration' unless row[:audio_s] > 0
            _, decode_log, result = Open3.capture3('ffmpeg', '-v', 'info', '-i', audio, '-af', 'volumedetect', '-f', 'null', '-')
            File.write(prefix + '.decode.log', decode_log)
            peak = decode_log.match(/max_volume:\s+(-?[\d.]+) dB/)
            raise 'Full decode failed or generated signal is silent' unless result.success? && peak && Float(peak[1]) > -60
            row[:peak_db] = Float(peak[1])
            row[:rtf_request] = row[:request_file_ready_s] / row[:audio_s]
            row[:characters_per_request_s] = text.length / row[:request_file_ready_s]
            row[:sha256] = Digest::SHA256.file(audio).hexdigest
            row[:status] = 'passed_full_decode'
          end
        rescue StandardError => error
          stop.call
          Process.waitpid(active) rescue nil if active
          active = nil
          row[:status] = 'failed'
          row[:error] = error.message
          row[:request_wall_s] = clock.call - started
        ensure
          pipe.close rescue nil
          writer.close rescue nil
          report[:runs] << row
          report[:active_attempt] = nil
          checkpoint.call
        end
        puts "RESULT #{engine} #{name} #{index + 1}: #{row[:status]} wall=#{row[:request_wall_s]&.round(3)} first_pcm=#{row[:first_non_silent_pcm_request_s]&.round(3)} rtf=#{row[:rtf_request]&.round(3)}"
        STDOUT.flush
      end
    end
  end
  report[:finished_utc] = Time.now.utc.iso8601
rescue Interrupt
  report[:interrupted_utc] = Time.now.utc.iso8601
  stop.call
  raise
ensure
  checkpoint.call
  lease.flock(File::LOCK_UN)
  lease.close
end
puts "REPORT #{report_path}"
exit(report[:runs].all? { |row| row[:status] == 'passed_full_decode' } ? 0 : 1)
