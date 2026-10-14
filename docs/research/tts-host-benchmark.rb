# frozen_string_literal: true

# A bounded, serial desktop reconnaissance benchmark; not a mobile benchmark.
# Run from the repository root: mise exec -- ruby docs/research/tts-host-benchmark.rb
require 'json'
require 'fileutils'
require 'digest'
require 'time'

root = File.expand_path('../..', __dir__)
Dir.chdir(root)
probe = File.join(root, 'target/debug/embedded_edge_probe')
abort 'Existing Edge probe is required; this harness never builds or downloads models.' unless File.executable?(probe)
stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
out = File.join(root, '.reports/tts-host', stamp)
FileUtils.mkdir_p(out)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
run = lambda do |command, input, prefix|
  started = clock.call
  status = nil
  File.open(input, 'r') do |stdin|
    File.open(prefix + '.stdout', 'w') do |stdout|
      File.open(prefix + '.stderr', 'w') do |stderr|
        pid = Process.spawn(*command, in: stdin, out: stdout, err: stderr, pgroup: true)
        deadline = clock.call + 45
        loop do
          result = Process.waitpid2(pid, Process::WNOHANG)
          if result
            status = result[1]
            break
          end
          if clock.call >= deadline
            Process.kill('TERM', -pid) rescue nil
            sleep 0.2
            Process.kill('KILL', -pid) rescue nil
            Process.waitpid(pid) rescue nil
            raise 'Command exceeded its 45 second bound'
          end
          sleep 0.01
        end
      end
    end
  end
  elapsed = clock.call - started
  raise "Command failed: #{File.read(prefix + '.stderr')[0, 800]}" unless status.success?
  elapsed
end
texts = {
  'short' => 'A biblioteca estava silenciosa. "Vamos começar?", perguntou Ana. Às 8h30, ela abriu o livro e leu a primeira página.',
  'paragraph' => 'Na manhã de terça-feira, Ana encontrou um livro antigo na biblioteca. A capa estava gasta, mas as páginas permaneciam legíveis. "Quanto custa?", perguntou ela. O funcionário respondeu: "Vinte e três reais e cinquenta centavos." Ana sorriu, conferiu o relógio às 8h30 e decidiu começar a leitura. No primeiro capítulo, um viajante atravessava a cidade em busca de notícias de sua família. Ele parou diante da estação, observou as pessoas e perguntou qual trem partiria às 14h15. A resposta chegou depressa: plataforma número 3. Mesmo com a chuva e o vento, o viajante continuou seu caminho. Não precisava correr; precisava apenas chegar antes do anoitecer.'
}
report = {
  'created_utc' => Time.now.utc.iso8601,
  'hardware' => 'Intel Core i5-8259U, 8 GiB RAM, x86_64 macOS desktop',
  'edge_binary' => probe,
  'edge_binary_sha256' => Digest::SHA256.file(probe).hexdigest,
  'edge_build_profile' => 'reused Debug probe, no compilation',
  'limitations' => ['Not physical mobile hardware', 'Three fresh processes per engine/input; shared OS voice services may stay warm', 'Different voices and speaking durations', 'TTFA, battery, thermals and total system memory are not measured', 'Apple child RSS excludes out-of-process speech services', 'No audio cache used by this harness; upstream caching is unknown', 'MP3 encoding included for Apple; Edge returns MP3 directly'],
  'corpora' => {}, 'runs' => []
}
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job owns the shared lease; no benchmark started.' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
begin
  texts.each do |name, text|
    input = File.join(out, name + '.txt')
    File.write(input, text)
    report['corpora'][name] = { 'text' => text, 'characters' => text.length, 'sha256' => Digest::SHA256.hexdigest(text) }
    3.times do |iteration|
      %w[apple edge].each do |engine|
        prefix = File.join(out, "#{name}-#{iteration + 1}-#{engine}")
        audio = prefix + '.mp3'
        row = { 'engine' => engine, 'corpus' => name, 'iteration' => iteration + 1, 'process_state' => 'fresh_process', 'audio' => audio }
        begin
          args = engine == 'edge' ? [probe, audio] : ['/usr/bin/say', '-v', 'Luciana', '-f', input, '-o', prefix + '.aiff']
          row['command'] = args
          row['synthesis_wall_s'] = run.call(['/usr/bin/time', '-l'] + args, input, prefix)
          row['encoding_wall_s'] = engine == 'edge' ? 0.0 : run.call(['ffmpeg', '-v', 'error', '-y', '-i', prefix + '.aiff', '-ac', '1', '-ar', '24000', '-b:a', '48k', audio], input, prefix + '-encode')
          row['artifact_ready_wall_s'] = row['synthesis_wall_s'] + row['encoding_wall_s']
          run.call(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_name,sample_rate,channels', '-of', 'json', audio], input, prefix + '-probe')
          metadata = JSON.parse(File.read(prefix + '-probe.stdout'))
          duration = Float(metadata.fetch('format').fetch('duration'))
          raise 'Audio has no positive duration' unless duration > 0
          run.call(['ffmpeg', '-v', 'info', '-i', audio, '-af', 'volumedetect', '-f', 'null', '-'], input, prefix + '-decode')
          volume = File.read(prefix + '-decode.stderr').match(/max_volume:\s+(-?[\d.]+) dB/)
          raise 'Audio is silent or its peak could not be validated' unless volume
          row['non_silent_peak_db'] = Float(volume[1])
          raise 'Audio peak is below the conservative speech-signal threshold' unless row['non_silent_peak_db'] > -60
          row['audio_duration_s'] = duration
          row['audio_metadata'] = metadata
          row['rtf_artifact_ready'] = row['artifact_ready_wall_s'] / duration
          row['characters_per_second'] = text.length / row['artifact_ready_wall_s']
          row['bytes'] = File.size(audio)
          row['sha256'] = Digest::SHA256.file(audio).hexdigest
          rss = File.read(prefix + '.stderr').match(/(\d+)\s+maximum resident set size/)
          row['child_peak_rss_bytes'] = rss && rss[1].to_i
          row['status'] = 'passed_full_decode'
        rescue StandardError => error
          row['status'] = 'failed'
          row['error'] = error.message
        end
        report['runs'] << row
        File.write(File.join(out, 'report.json'), JSON.pretty_generate(report) + "\n")
        puts "#{engine} #{name} #{iteration + 1}: #{row['status']} ready=#{row['artifact_ready_wall_s']} rtf=#{row['rtf_artifact_ready']}"
        STDOUT.flush
      end
    end
  end
ensure
  lease.flock(File::LOCK_UN)
  lease.close
end
puts "report=#{File.join(out, 'report.json')}"
exit(report['runs'].all? { |r| r['status'] == 'passed_full_decode' } ? 0 : 1)
