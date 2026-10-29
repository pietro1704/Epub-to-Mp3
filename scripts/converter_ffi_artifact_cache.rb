# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Retains authenticated packages, not just installed dylibs without provenance.
# Every reuse still runs the producer's source, payload and native verifier.
module ConverterFfiArtifactCache
  RELATIVE_ROOT = 'target/native-prebuilt/converter-ffi-macos-intel'.freeze
  module_function

  def remember(root, package)
    receipt = JSON.parse(File.read(File.join(package, 'receipt.json')))
    identity = receipt.fetch('identity_sha256')
    raise 'Invalid cache identity' unless identity.match?(/\A[0-9a-f]{64}\z/)
    payload = Digest::SHA256.hexdigest(JSON.generate(receipt.fetch('files').sort.to_h))
    parent = File.join(root, RELATIVE_ROOT)
    FileUtils.mkdir_p(parent)
    raise 'Artifact cache root must not be a symlink' if File.symlink?(parent)
    destination = File.join(parent, "#{identity}-#{payload}")
    File.open(File.join(parent, '.lock'), 'a+', 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      if File.exist?(destination) || File.symlink?(destination)
        raise 'Artifact cache entry must be a plain directory' unless File.directory?(destination) && !File.symlink?(destination)
        retained = File.join(destination, 'receipt.json')
        raise 'Retained receipt must be a regular file' unless File.file?(retained) && !File.symlink?(retained)
        previous = JSON.parse(File.read(retained))
        raise 'Retained receipt changed; preserving it for inspection' unless previous['identity_sha256'] == identity && previous['files'] == receipt['files']
        receipt.fetch('files').each do |relative, hash|
          file = File.join(destination, relative)
          raise 'Retained artifact changed; preserving it for inspection' unless File.file?(file) && !File.symlink?(file) && Digest::SHA256.file(file).hexdigest == hash
        end
        return destination
      end
      temporary = Dir.mktmpdir('.package-', parent)
      begin
        FileUtils.cp_r(Dir.children(package).map { |name| File.join(package, name) }, temporary)
        File.rename(temporary, destination)
      ensure
        FileUtils.remove_entry(temporary) if File.directory?(temporary)
      end
    end
    destination
  end

  def find(root:, identity_sha:, verify_package:)
    raise 'Invalid expected cache identity' unless identity_sha.match?(/\A[0-9a-f]{64}\z/)
    roots = [File.expand_path(root)]
    output, _, status = Open3.capture3('git', '-C', root, 'worktree', 'list', '--porcelain', '-z')
    roots += output.split("\0").filter_map { |line| line.delete_prefix('worktree ') if line.start_with?('worktree ') } if status.success?
    roots.filter_map { |checkout| File.realpath(checkout) if File.directory?(checkout) }.uniq.each do |checkout|
      parent = File.join(checkout, RELATIVE_ROOT)
      next if File.symlink?(parent)
      Dir.glob(File.join(parent, "#{identity_sha}-*")).sort.each do |package|
        next unless File.directory?(package) && !File.symlink?(package)
        begin
          verify_package.call(root, package, identity_sha)
          return package
        rescue StandardError
          # Preserve rejected bytes; another verified package may still match.
          next
        end
      end
    end
    nil
  end
end
