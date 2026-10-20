require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

class CliFaberVerification
  class Failure < StandardError; end
  MODEL = 'pt_BR-faber-medium'.freeze
  PREFERENCES = {
    'primary' => {'engine' => 'piper', 'model_id' => MODEL, 'voice' => nil},
    'secondary' => nil, 'allow_online_fallback' => false
  }.freeze
  ARTIFACTS = {
    'model.onnx' => [63_201_294, '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7'],
    'model.onnx.json' => [4_855, '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f']
  }.freeze

  def initialize(cli:, sample:, reports:, temporary_root: Dir.tmpdir)
    @cli = File.expand_path(cli)
    @sample = File.expand_path(sample)
    @reports = File.expand_path(reports)
    @temporary_root = File.realpath(temporary_root)
    @sequence = 0
    FileUtils.mkdir_p(@reports)
  end

  def require_condition(value, message)
    raise Failure, message unless value
  end

  def command!(argv, environment: {}, allow_failure: false, chdir: nil)
    stdout, stderr, status = Open3.capture3(environment, *argv, **(chdir ? {chdir: chdir} : {}))
    @sequence += 1
    File.write(File.join(@reports, format('%02d.stdout.log', @sequence)), stdout)
    File.write(File.join(@reports, format('%02d.stderr.log', @sequence)), stderr)
    require_condition(status.success? || allow_failure, "#{File.basename(argv.first)} failed (#{status.exitstatus}): #{stderr}")
    [stdout, stderr, status]
  rescue SystemCallError => error
    raise Failure, "Required executable failed: #{error.message}"
  end

  def cli!(*arguments, allow_failure: false)
    require_condition(File.file?(@cli) && File.executable?(@cli), 'The explicitly packaged CLI executable is missing')
    command!([@cli, *arguments], environment: @environment || {}, allow_failure: allow_failure,
      chdir: @working_directory)
  end

  def safe_child(root, name)
    require_condition(name.is_a?(String) && !name.empty? && !name.include?("\0") &&
      !name.include?('\\') && !%w[. ..].include?(name) && File.basename(name) == name,
      'Artifact name must be a direct child')
    path = File.expand_path(File.join(root, name))
    require_condition(File.dirname(path) == File.expand_path(root) && !File.symlink?(path),
      'Artifact identity escapes its output directory')
    path
  end

  def validate_manifest_identity!(manifest, output_root)
    job_directory = safe_child(output_root, manifest.fetch('jobId'))
    require_condition(File.directory?(job_directory), 'CLI job directory is missing')
    require_condition(manifest['chapters'].is_a?(Array) && manifest['chapters'].length == 2 &&
      manifest['chapters'].map { |chapter| chapter['sourceIndex'] } == [0, 1] &&
      manifest['sourceChaptersTotal'] == 2, 'CLI must convert exactly the two requested source chapters')
    require_condition(manifest['ttsPreferences'] == PREFERENCES, 'Effective CLI preferences differ from the explicit offline Faber selection')
    require_condition(manifest['usedSelections'] == [PREFERENCES['primary']], 'Actual synthesis did not use only the selected Faber model')
    require_condition(manifest.fetch('fallbackUsed', false) == false, 'CLI used an unexpected fallback')
    require_condition(manifest.dig('ttsPolicyState', 'consecutive_failures') == 0, 'CLI did not persist its successful policy reset')
    job_directory
  end

  def verify_models!(persistent)
    directory = File.join(persistent, 'models', 'tts', MODEL)
    ARTIFACTS.each do |name, (bytes, digest)|
      path = safe_child(directory, name)
      require_condition(File.file?(path) && File.size(path) == bytes &&
        Digest::SHA256.file(path).hexdigest == digest, "Explicit model installation failed verification: #{name}")
    end
  end

  def verify_receipt!(receipt, audio)
    # Typed synthesis records authoritative selections; the legacy provider hint
    # can legitimately be absent when the portable typed pipeline produced audio.
    require_condition(receipt['version'] == 2 && [nil, 'piper'].include?(receipt['provider']) &&
      receipt['fallback_used'] == false && receipt['used_selections'] == [PREFERENCES['primary']] &&
      receipt['request_key'].is_a?(String) && receipt['request_key'].match?(/\A[0-9a-f]{64}\z/) &&
      receipt['size'] == File.size(audio) && receipt['audio_sha256'] == Digest::SHA256.file(audio).hexdigest,
      'CLI receipt does not identify the completed offline Faber audio')
  end

  def self.cleanup_owned!(reports:, temporary_root:)
    registry = File.join(reports, 'owned-root.txt')
    return unless File.file?(registry)
    work = File.expand_path(File.read(registry).strip)
    parent = File.realpath(temporary_root)
    raise Failure, 'Refusing cleanup outside the owned temporary directory' unless
      File.dirname(work) == parent && File.basename(work).start_with?('cli-faber-owned-')
    return unless File.exist?(work)
    marker = File.join(work, '.cli-faber-verification-owned')
    raise Failure, 'Refusing cleanup without the owned marker' unless
      !File.symlink?(work) && !File.symlink?(marker) && File.file?(marker) && File.read(marker) == "cli-faber-v1\n"
    FileUtils.remove_entry(work)
  end

  def verify_audio!(path, work)
    probe, = command!([ENV.fetch('FFPROBE', '/usr/bin/ffprobe'), '-v', 'error',
      '-select_streams', 'a:0', '-show_entries', 'stream=codec_name,sample_rate,channels',
      '-of', 'json', path])
    stream = JSON.parse(probe).fetch('streams').first
    require_condition(stream && stream['codec_name'] == 'mp3' &&
      stream['sample_rate'] == '24000' && stream['channels'] == 1, 'CLI output is not normalized mono MP3')
    pcm = File.join(work, 'decoded.f32le')
    command!([ENV.fetch('FFMPEG', '/usr/bin/ffmpeg'), '-nostdin', '-v', 'error', '-xerror',
      '-i', path, '-map', '0:a:0', '-f', 'f32le', '-acodec', 'pcm_f32le', '-y', pcm])
    bytes = File.binread(pcm)
    require_condition(!bytes.empty? && bytes.bytesize % 4 == 0, 'Full MP3 decode produced invalid PCM')
    samples = bytes.unpack('e*')
    require_condition(samples.all?(&:finite?), 'Full MP3 decode contains non-finite samples')
    peak = samples.map(&:abs).max
    require_condition(peak > 0.001, 'Full MP3 decode is silent')
    {'samples' => samples.length, 'peak' => peak, 'codec' => stream}
  end

  def run!
    require_condition(File.file?(@sample), 'The public sample EPUB is missing')
    work = Dir.mktmpdir('cli-faber-owned-', @temporary_root)
    persistent = File.join(work, 'persistent')
    output = File.join(work, 'outputs')
    @working_directory = work
    @environment = {'PERSISTENT_ROOT' => persistent, 'ENGINE' => nil,
      'LD_LIBRARY_PATH' => File.dirname(@cli), 'ORT_DYLIB_PATH' => nil, 'ORT_LIB_LOCATION' => nil,
      'ESPEAK_DATA_DIRECTORY' => nil, 'PIPER_ESPEAKNG_DATA_DIRECTORY' => nil}
    begin
      File.write(File.join(work, '.cli-faber-verification-owned'), "cli-faber-v1\n")
      File.write(File.join(@reports, 'owned-root.txt'), work)
      defaults, = cli!('preferences', 'show')
      require_condition(JSON.parse(defaults) == PREFERENCES, 'Fresh CLI preferences do not default to offline Faber')
      cli!('preferences', 'set', JSON.generate(PREFERENCES))
      saved, = cli!('preferences', 'show')
      require_condition(JSON.parse(saved) == PREFERENCES, 'Public preference save/show did not round trip')
      listing, = cli!('models', 'list')
      require_condition(listing.lines.any? { |line| line.start_with?("#{MODEL}\t") && line.include?('not installed') },
        'Fresh CLI model storage must be empty')
      arguments = ['convert', @sample, '--chapter', 'position:0', '--chapter', 'position:1',
        '--no-parallel', '--fallback-engine', 'none', '--output-dir', output]
      _, error, rejected = cli!(*arguments, allow_failure: true)
      require_condition(!rejected.success? && error.match?(/Piper model .* is not installed/),
        'Pre-install conversion must fail specifically for missing Faber, never for a missing runtime')
      require_condition(Dir.glob(File.join(work, '**', '*.mp3')).empty? &&
        Dir.glob(File.join(work, '**', '*.onnx*')).empty?, 'Conversion implicitly downloaded a model or emitted audio')
      cli!('models', 'install', MODEL)
      verify_models!(persistent)
      installed, = cli!('models', 'list')
      require_condition(installed.lines.any? { |line| line.start_with?("#{MODEL}\t") &&
        line.strip.end_with?("\tinstalled") }, 'Explicit public installation was not recorded')
      stdout, = cli!(*arguments)
      manifest = JSON.parse(stdout)
      job = validate_manifest_identity!(manifest, output)
      persisted = JSON.parse(File.read(safe_child(job, 'manifest.json')))
      require_condition(persisted == manifest, 'Printed and durable CLI manifests disagree')
      evidence = manifest.fetch('chapters').map do |chapter|
        audio = safe_child(job, chapter.fetch('filename'))
        require_condition(File.file?(audio), 'CLI chapter audio is missing')
        receipt_path = safe_child(job, "#{chapter.fetch('filename')}.complete.json")
        receipt = JSON.parse(File.read(receipt_path))
        verify_receipt!(receipt, audio)
        verify_audio!(audio, work).merge('filename' => chapter['filename'], 'sourceIndex' => chapter['sourceIndex'],
          'audioSha256' => receipt['audio_sha256'])
      end
      archive = safe_child(job, manifest.fetch('archive'))
      command!(['/usr/bin/unzip', '-t', archive])
      entries, = command!(['/usr/bin/unzip', '-Z1', archive])
      require_condition(entries.lines.map(&:strip).select { |name| name.end_with?('.mp3') }.map { |name| File.basename(name) }.sort ==
        manifest['chapters'].map { |chapter| chapter['filename'] }.sort, 'CLI archive differs from its two completed chapters')
      verify_models!(persistent)
      File.write(File.join(@reports, 'manifest.json'), JSON.pretty_generate(manifest))
      File.write(File.join(@reports, 'evidence.json'), JSON.pretty_generate({'publicCli' => @cli,
        'explicitInstall' => true, 'implicitInstallRejected' => true, 'chapters' => evidence}))
      puts 'CLI_FABER_GOLDEN chapters=2 engine=piper model=pt_BR-faber-medium fallback=false'
    ensure
      # This directory was freshly allocated by this invocation; never remove user state.
      FileUtils.remove_entry(work) if File.exist?(work)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('..', __dir__)
  begin
    if ARGV.first == '--cleanup-owned'
      CliFaberVerification.cleanup_owned!(reports: File.join(root, '.reports/cli-faber'),
        temporary_root: ENV.fetch('RUNNER_TEMP', Dir.tmpdir))
      exit 0
    end
    CliFaberVerification.new(
      cli: ARGV.fetch(0, File.join(root, 'dist/epub-to-mp3-cli/bin/converter-cli')),
      sample: File.join(root, 'web/public/sample.epub'),
      reports: File.join(root, '.reports/cli-faber'),
      temporary_root: ENV.fetch('RUNNER_TEMP', Dir.tmpdir)
    ).run!
  rescue CliFaberVerification::Failure, JSON::ParserError, KeyError, SystemCallError => error
    warn "CLI_FABER_GOLDEN failed: #{error.message}"
    exit 1
  end
end
