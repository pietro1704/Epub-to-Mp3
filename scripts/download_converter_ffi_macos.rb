#!/usr/bin/env ruby
# Download the exact trusted Intel macOS FFI artifact selected from GitHub Actions.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'pathname'
require 'tmpdir'
require 'time'
require 'uri'
require_relative 'converter_ffi_artifact_cache'

module ConverterFfiMacOSDownloader
  REPOSITORY = 'pietro1704/Epub-to-Mp3'.freeze
  WORKFLOW = '.github/workflows/converter-ffi-macos-intel-prebuilt.yml'.freeze
  ARTIFACT_NAME = 'converter-ffi-macos-intel-x86_64-v1'.freeze
  ARTIFACT_WORKFLOW = 'converter-ffi-macos-intel-prebuilt'.freeze
  API = URI('https://api.github.com').freeze
  ALLOWED_DOWNLOAD_SUFFIXES = %w[github.com githubusercontent.com actions.githubusercontent.com blob.core.windows.net amazonaws.com azureedge.net].freeze
  MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
  MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
  MAX_ENTRIES = 20_000
  DATA_DESTINATION = 'release/build/espeak-rs-sys-prebuilt/out/build/espeak-ng-data'.freeze

  class HttpClient
    def initialize(token, api_base: API)
      @token = token
      @api_base = api_base
    end

    def json(path)
      response = request(api_uri(path), { 'Accept' => 'application/vnd.github+json' })
      raise "GitHub API returned HTTP #{response.code} for #{path}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end

    def archive(path, destination)
      response = stream_request(api_uri(path), { 'Accept' => 'application/vnd.github+json' }, destination)
      5.times do
        return destination if response.is_a?(Net::HTTPSuccess)
        raise "GitHub artifact endpoint returned HTTP #{response.code}" unless response.is_a?(Net::HTTPRedirection)

        location = URI.join(response.uri.to_s, response['location'])
        raise 'Artifact download redirect must use HTTPS' unless location.scheme == 'https'
        raise 'Artifact download redirect contains credentials' if location.userinfo
        raise 'Artifact download redirect host is not trusted' unless trusted_download_host?(location.host)
        response = stream_request(location, {}, destination)
      end
      raise 'Too many artifact download redirects'
    end

    private

    def api_uri(path)
      raise 'GitHub API path must be absolute and local to the fixed API host' unless path.start_with?('/') && !path.start_with?('//')
      URI.join(@api_base.to_s, path)
    end

    def request(uri, headers)
      raise 'GitHub request must use HTTPS' unless uri.scheme == 'https'
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'epubtomp3-ffi-prebuilt-downloader'
      request['X-GitHub-Api-Version'] = '2022-11-28'
      headers.each { |key, value| request[key] = value }
      request['Authorization'] = "Bearer #{@token}" if uri.host == @api_base.host
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 120
      http.start do |connection|
        connection.request(request).tap { |response| response.define_singleton_method(:uri) { uri } }
      end
    end

    def stream_request(uri, headers, destination)
      raise 'GitHub request must use HTTPS' unless uri.scheme == 'https'
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'epubtomp3-ffi-prebuilt-downloader'
      request['X-GitHub-Api-Version'] = '2022-11-28'
      headers.each { |key, value| request[key] = value }
      request['Authorization'] = "Bearer #{@token}" if uri.host == @api_base.host
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 120
      response = nil
      http.start do |connection|
        connection.request(request) do |result|
          response = result
          result.define_singleton_method(:uri) { uri }
          if result.is_a?(Net::HTTPSuccess)
            received = 0
            File.open(destination, 'wb', 0o600) do |file|
              result.read_body do |chunk|
                received += chunk.bytesize
                raise 'Downloaded artifact exceeds the size limit' if received > MAX_ARCHIVE_BYTES
                file.write(chunk)
              end
            end
          else
            result.read_body { |_chunk| }
          end
        end
      end
      response
    end

    def trusted_download_host?(host)
      host == @api_base.host || ALLOWED_DOWNLOAD_SUFFIXES.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
    end
  end

  module_function

  def canonical_json(value)
    JSON.generate(sort_hash(value))
  end

  def sort_hash(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort_hash(value.fetch(key))] }
    when Array then value.map { |item| sort_hash(item) }
    else value
    end
  end

  def download(root:, run_id:, run_attempt:, token:, api_base: API, now: Time.now.utc, client: nil, verify_package: nil)
    validate_numeric!(run_id, 'run ID')
    validate_numeric!(run_attempt, 'run attempt')
    client ||= HttpClient.new(token, api_base: api_base)
    run = client.json("/repos/#{REPOSITORY}/actions/runs/#{run_id}")
    validate_run!(run, run_id, run_attempt)
    artifact = find_artifact(client, run_id)
    validate_artifact!(artifact, now)

    Dir.mktmpdir('converter-ffi-download-') do |temporary|
      zip = File.join(temporary, 'artifact.zip')
      client.archive("/repos/#{REPOSITORY}/actions/artifacts/#{artifact.fetch('id')}/zip", zip)
      raise 'Downloaded artifact exceeds the size limit' if File.size(zip) > MAX_ARCHIVE_BYTES
      actual_digest = Digest::SHA256.file(zip).hexdigest
      expected_digest = artifact.fetch('digest').delete_prefix('sha256:')
      raise 'Downloaded artifact digest does not match GitHub metadata' unless actual_digest == expected_digest

      extracted = File.join(temporary, 'package')
      extract_package(zip, extracted)
      receipt = validate_receipt!(extracted, run, run_id, run_attempt)
      verify_package ||= method(:verify_with_producer)
      verify_package.call(root, extracted, receipt.fetch('identity_sha256'))
      ConverterFfiArtifactCache.remember(root, extracted)
      install_package(root, extracted)
    end
    puts "Installed verified Intel converter-ffi from Actions run #{run_id} attempt #{run_attempt}"
  end

  def validate_numeric!(value, description)
    raise "#{description} must be a positive integer" unless value.to_s.match?(/\A[1-9][0-9]*\z/)
  end

  def validate_run!(run, run_id, run_attempt)
    raise 'Actions run ID mismatch' unless run['id'].to_s == run_id
    raise 'Actions run attempt mismatch' unless run['run_attempt'].to_s == run_attempt
    raise 'Actions run did not complete successfully' unless run['status'] == 'completed' && run['conclusion'] == 'success'
    raise 'Actions run must target master' unless run['head_branch'] == 'master'
    raise 'Actions run must come from the trusted repository' unless run.dig('head_repository', 'full_name') == REPOSITORY
    raise 'Actions run must use the manual producer workflow' unless run['event'] == 'workflow_dispatch' && run['path'] == WORKFLOW
    raise 'Actions run SHA is invalid' unless run['head_sha'].to_s.match?(/\A[0-9a-f]{40}\z/)
  end

  def find_artifact(client, run_id)
    response = client.json("/repos/#{REPOSITORY}/actions/runs/#{run_id}/artifacts?per_page=100")
    artifacts = response.fetch('artifacts')
    raise 'Actions artifact listing is incomplete' unless response.fetch('total_count') == artifacts.length
    matches = artifacts.select { |artifact| artifact['name'] == ARTIFACT_NAME }
    raise 'Trusted FFI artifact is missing or ambiguous' unless matches.length == 1
    matches.first
  end

  def validate_artifact!(artifact, now)
    raise 'Actions artifact expiration status is missing or expired' unless artifact['expired'] == false
    expiry = Time.parse(artifact.fetch('expires_at'))
    raise 'Actions artifact has expired' unless expiry > now
    raise 'Actions artifact size is invalid' unless artifact.fetch('size_in_bytes').to_i.positive? && artifact.fetch('size_in_bytes').to_i <= MAX_ARCHIVE_BYTES
    raise 'Actions artifact digest is invalid' unless artifact.fetch('digest').match?(/\Asha256:[0-9a-f]{64}\z/)
    validate_numeric!(artifact.fetch('id'), 'artifact ID')
    created = Time.parse(artifact.fetch('created_at'))
    raise 'Actions artifact retention exceeds the 90-day contract' if expiry > created + (91 * 24 * 60 * 60)
  end

  # Inspect the central directory before invoking unzip. Reject zip-slip paths,
  # symlinks, duplicate names, encrypted/Zip64 entries and unreasonable sizes.
  def zip_entries(path)
    bytes = File.binread(path)
    lower = [0, bytes.bytesize - 65_557].max
    eocd_offset = bytes.rindex("PK\x05\x06".b)
    raise 'Invalid or unsupported ZIP archive' unless eocd_offset && eocd_offset >= lower && eocd_offset + 22 <= bytes.bytesize
    eocd = bytes.byteslice(eocd_offset, 22).unpack('VvvvvVVv')
    _signature, disk, central_disk, disk_count, count, central_size, central_offset, comment_length = eocd
    raise 'Multi-disk and Zip64 artifacts are not supported' unless disk.zero? && central_disk.zero? && disk_count == count && count < 0xffff && central_size < 0xffffffff && central_offset < 0xffffffff
    raise 'Invalid ZIP end record' unless eocd_offset + 22 + comment_length == bytes.bytesize && central_offset + central_size <= eocd_offset
    raise 'Artifact contains too many files' if count > MAX_ENTRIES

    position = central_offset
    names = {}
    entries = []
    expanded_size = 0
    count.times do
      header = bytes.byteslice(position, 46)
      raise 'Invalid ZIP central directory' unless header&.bytesize == 46 && header.unpack1('V') == 0x02014b50
      fields = header.unpack('VvvvvvvVVVvvvvvVV')
      _signature, made_by, needed, flags, _method, _time, _date, _crc, compressed, uncompressed,
        name_length, extra_length, file_comment_length, start_disk, _internal, external, local_offset = fields
      raise 'Encrypted ZIP entries are not supported' unless (flags & 1).zero?
      raise 'Multi-disk ZIP entries are not supported' unless start_disk.zero?
      raise 'Zip64 ZIP entries are not supported' if [compressed, uncompressed, local_offset].include?(0xffffffff)
      name = bytes.byteslice(position + 46, name_length)
      raise 'Invalid ZIP entry name' unless name&.bytesize == name_length && name.force_encoding(Encoding::UTF_8).valid_encoding?
      name = name.dup
      raise 'Artifact contains duplicate paths' if names.key?(name)
      names[name] = true
      validate_entry_path!(name)
      mode = (made_by >> 8) == 3 ? (external >> 16) : 0
      raise 'Artifact contains a symlink or special file' unless mode.zero? || [0o100000, 0o040000].include?(mode & 0o170000)
      raise 'Artifact contains a symlink or special file' if (mode & 0o170000) == 0o120000
      raise 'Artifact contains an unsupported local ZIP entry' unless local_offset + 30 <= bytes.bytesize && bytes.byteslice(local_offset, 4).unpack1('V') == 0x04034b50
      local_name_length, local_extra_length = bytes.byteslice(local_offset + 26, 4).unpack('vv')
      local_name = bytes.byteslice(local_offset + 30, local_name_length)
      raise 'ZIP local and central entry names differ' unless local_name == name
      raise 'ZIP local entry is truncated' unless local_offset + 30 + local_name_length + local_extra_length + compressed <= bytes.bytesize
      expanded_size += uncompressed
      raise 'Artifact expands beyond the size limit' if expanded_size > MAX_EXPANDED_BYTES
      entries << name
      position += 46 + name_length + extra_length + file_comment_length
    end
    raise 'Invalid ZIP central directory size' unless position == central_offset + central_size
    entries
  end

  def validate_entry_path!(name)
    raise 'Artifact contains an unsafe path' if name.empty? || name.start_with?('/', '\\') || name.include?("\0") || name.include?('\\')
    directory = name.end_with?('/')
    parts = name.delete_suffix('/').split('/', -1)
    raise 'Artifact contains an unsafe path' if parts.empty? || parts.any? { |part| part.empty? || part == '.' || part == '..' }
    relative = parts.join('/')
    allowed = relative == 'libconverter_ffi.dylib' || relative == 'receipt.json' || relative == 'espeak-ng-data' || relative.start_with?('espeak-ng-data/')
    raise 'Artifact contains an unexpected file' unless allowed
    raise 'Artifact root files cannot be directories' if directory && %w[libconverter_ffi.dylib receipt.json].include?(relative)
  end

  def extract_package(zip, destination)
    entries = zip_entries(zip)
    raise 'Artifact is empty' if entries.empty?
    FileUtils.mkdir_p(destination, mode: 0o700)
    output, status = Open3.capture2e('unzip', '-qq', zip, '-d', destination)
    raise "Safe artifact extraction failed: #{output}" unless status.success?
    actual_files = []
    actual_directories = []
    Find.find(destination) do |path|
      next if path == destination
      stat = File.lstat(path)
      raise 'Extracted artifact contains a symlink or special file' unless stat.file? || stat.directory?
      relative = path.delete_prefix("#{destination}/")
      stat.directory? ? actual_directories << relative : actual_files << relative
    end
    expected_files = entries.reject { |entry| entry.end_with?('/') }.sort
    expected_directories = entries.select { |entry| entry.end_with?('/') }.map { |entry| entry.delete_suffix('/') }.uniq
    implied_directories = expected_files.flat_map { |file| Pathname(file).ascend.map(&:to_s)[1..] }
    allowed_directories = (expected_directories + implied_directories).uniq
    raise 'Extracted artifact file paths differ from its ZIP index' unless actual_files.sort == expected_files
    raise 'Extracted artifact contains an unexpected directory' unless (actual_directories - allowed_directories).empty?
    files = actual_files.sort
    raise 'Artifact package contains unexpected files' unless files.all? { |path| path == 'libconverter_ffi.dylib' || path == 'receipt.json' || path.start_with?('espeak-ng-data/') }
    raise 'Artifact package is incomplete' unless %w[libconverter_ffi.dylib receipt.json espeak-ng-data/phontab espeak-ng-data/phondata].all? { |path| files.include?(path) }
    destination
  end

  def validate_receipt!(package, run, run_id, run_attempt)
    receipt = JSON.parse(File.read(File.join(package, 'receipt.json')))
    raise 'Unsupported FFI receipt schema' unless receipt['schema_version'] == 1
    identity = receipt.fetch('identity')
    identity_sha = Digest::SHA256.hexdigest(canonical_json(identity))
    raise 'FFI build identity digest is invalid' unless receipt['identity_sha256'] == identity_sha
    raise 'FFI artifact architecture or target is invalid' unless identity['platform'] == 'macos' && identity['architecture'] == 'x86_64' && identity['rust_target'] == 'x86_64-apple-darwin'
    raise 'FFI receipt source commit does not match its producer run' unless receipt['source_sha'] == run.fetch('head_sha')
    producer = receipt.fetch('producer')
    expected_producer = {
      'workflow' => ARTIFACT_WORKFLOW,
      'event' => 'workflow_dispatch',
      'ref' => 'refs/heads/master',
      'run_id' => run_id,
      'run_attempt' => run_attempt
    }
    raise 'FFI receipt producer identity does not match Actions run' unless producer == expected_producer
    files = {}
    Find.find(package) do |path|
      next unless File.file?(path) && path != File.join(package, 'receipt.json')
      files[path.delete_prefix("#{package}/")] = Digest::SHA256.file(path).hexdigest
    end
    raise 'FFI receipt payload hashes do not match the artifact' unless receipt['files'] == files.sort.to_h
    receipt
  end

  def verify_with_producer(root, package, identity_sha)
    helper = File.join(root, 'scripts', 'package_converter_ffi_macos.rb')
    raise 'Trusted FFI package verifier is missing; producer PR1 must be integrated first' unless File.file?(helper)
    output, status = Open3.capture2e('ruby', helper, 'verify', '--root', root, '--package', package, '--expected-identity-sha', identity_sha)
    raise "Producer package verification failed: #{output}" unless status.success?
  end

  def install_package(root, package, rename: File.method(:rename))
    require 'find'
    target = File.join(root, 'target')
    release = File.join(target, 'release')
    data_parent = File.join(target, 'espeak-data', File.dirname(DATA_DESTINATION))
    data_destination = File.join(target, 'espeak-data', DATA_DESTINATION)
    receipt = JSON.parse(File.read(File.join(package, 'receipt.json')))
    installed = receipt.fetch('files').all? do |relative, digest|
      path = relative == 'libconverter_ffi.dylib' ? File.join(release, relative) : File.join(data_destination, relative.delete_prefix('espeak-ng-data/'))
      File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == digest
    end
    return if installed
    FileUtils.mkdir_p(release)
    FileUtils.mkdir_p(data_parent)
    stage_library = File.join(release, ".libconverter_ffi.dylib.#{Process.pid}.tmp")
    stage_data = File.join(data_parent, ".espeak-ng-data.#{Process.pid}.tmp")
    library = File.join(release, 'libconverter_ffi.dylib')
    backup_library = "#{library}.prebuilt-previous"
    backup_data = "#{data_destination}.prebuilt-previous"
    [stage_library, stage_data, backup_library, backup_data].each do |path|
      raise "Preserving previous artifact at #{path}; inspect before retrying" if File.exist?(path) || File.symlink?(path)
    end
    library_existed = File.exist?(library) || File.symlink?(library)
    data_existed = File.exist?(data_destination) || File.symlink?(data_destination)
    begin
      FileUtils.cp(File.join(package, 'libconverter_ffi.dylib'), stage_library)
      FileUtils.cp_r(File.join(package, 'espeak-ng-data'), stage_data)
      raise 'Prebuilt FFI install staging is incomplete' unless File.file?(stage_library) && File.file?(File.join(stage_data, 'phontab')) && File.file?(File.join(stage_data, 'phondata'))
      rename.call(library, backup_library) if library_existed
      rename.call(data_destination, backup_data) if data_existed
      rename.call(stage_library, library)
      rename.call(stage_data, data_destination)
    rescue Exception
      FileUtils.rm_f(library) if File.exist?(backup_library) || (!library_existed && !File.exist?(stage_library) && File.exist?(library))
      FileUtils.rm_rf(data_destination) if File.exist?(backup_data) || (!data_existed && !File.exist?(stage_data) && File.exist?(data_destination))
      rename.call(backup_library, library) if File.exist?(backup_library)
      rename.call(backup_data, data_destination) if File.exist?(backup_data)
      raise
    ensure
      FileUtils.rm_f(stage_library)
      FileUtils.rm_rf(stage_data)
    end
  end

  def main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: download_converter_ffi_macos.rb --run-id ID --run-attempt N'
      parser.on('--root PATH') { |value| options[:root] = File.expand_path(value) }
      parser.on('--run-id ID') { |value| options[:run_id] = value }
      parser.on('--run-attempt N') { |value| options[:run_attempt] = value }
      parser.on('--reuse-local') { options[:reuse_local] = true }
    end.parse!(argv)
    raise 'Unexpected positional arguments' unless argv.empty?
    root = options.fetch(:root, File.expand_path('..', __dir__))
    if options[:reuse_local]
      raise 'Offline reuse cannot also select an Actions run' if options[:run_id] || options[:run_attempt]
      require_relative 'package_converter_ffi_macos'
      identity = Digest::SHA256.hexdigest(canonical_json(ConverterFfiMacOSPackage.identity(root)))
      package = ConverterFfiArtifactCache.find(root: root, identity_sha: identity, verify_package: method(:verify_with_producer))
      raise 'No verified local FFI package matches these sources; inspect trusted artifacts before authorizing a build' unless package
      install_package(root, package)
      puts "Reused verified Intel converter-ffi package #{File.basename(package)} without compilation or network access"
      return 0
    end
    token = ENV['GH_TOKEN'] || ENV['GITHUB_TOKEN']
    raise 'GH_TOKEN or GITHUB_TOKEN is required' if token.to_s.empty?
    download(root: root, run_id: options.fetch(:run_id), run_attempt: options.fetch(:run_attempt), token: token)
    0
  rescue StandardError => error
    warn "error: #{error.message}"
    1
  end
end

exit ConverterFfiMacOSDownloader.main(ARGV) if $PROGRAM_NAME == __FILE__
