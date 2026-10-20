# frozen_string_literal: true

require 'digest'
require 'json'
require 'tempfile'

# No subprocesses or toolchain probes: passive verification reads local bytes only.
module DeviceWorkflowReceipt
  def self.sources(root)
    directory = File.join(root, 'tools/DeviceWorkflow/Sources')
    raise 'Missing sources directory' unless File.directory?(directory) && !File.symlink?(directory)
    paths = ['scripts/device-workflow.sh', 'scripts/device_workflow_receipt.rb', 'tools/DeviceWorkflow/Package.swift']
    paths += Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).reject { |p| ['.', '..'].include?(File.basename(p)) }.map do |path|
      raise 'Symlink source input' if File.symlink?(path)
      path.delete_prefix(root + '/') unless File.directory?(path)
    end
    paths.compact!
    lock = 'tools/DeviceWorkflow/Package.resolved'
    paths << lock if File.exist?(File.join(root, lock)) || File.symlink?(File.join(root, lock))
    digest = Digest::SHA256.new
    digest.update(JSON.generate(['root', File.realpath(root)]))
    paths.sort.each do |relative|
      path = File.join(root, relative)
      raise 'Invalid source input' unless File.file?(path) && !File.symlink?(path)
      digest.update(JSON.generate([relative, Digest::SHA256.file(path).hexdigest]))
    end
    digest.update(JSON.generate(['DEVELOPER_DIR', ENV['DEVELOPER_DIR'], 'TOOLCHAINS', ENV['TOOLCHAINS']]))
    digest.hexdigest
  end

  def self.binary(path)
    raise 'Invalid prepared binary' unless File.file?(path) && File.executable?(path) && !File.symlink?(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.run(action, root, expected = nil)
    cache = File.join(root, 'ios/EpubToMp3/.build/device-workflow')
    receipt = File.join(cache, 'preparation.json')
    executable = File.join(cache, 'debug/device-workflow')
    identity = sources(root)
    case action
    when 'snapshot' then puts identity
    when 'record'
      raise 'Sources changed during preparation' unless identity == expected
      payload = JSON.generate({ 'schemaVersion' => 1, 'sources' => identity, 'binary' => binary(executable) })
      Tempfile.create(['preparation-', '.json'], cache) do |file|
        file.write(payload)
        file.flush
        file.fsync
        File.rename(file.path, receipt)
      end
    when 'verify'
      stored = JSON.parse(File.read(receipt))
      raise 'Preparation receipt mismatch' unless stored == { 'schemaVersion' => 1, 'sources' => identity, 'binary' => binary(executable) }
    else raise 'Invalid receipt action'
    end
  end
end

begin
  DeviceWorkflowReceipt.run(*ARGV)
rescue StandardError => error
  warn "Device workflow preparation verification failed: #{error.message}"
  exit 1
end
