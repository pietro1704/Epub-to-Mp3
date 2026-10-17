#!/usr/bin/env ruby
# Build a deployment repository from tracked runtime inputs, never from root rsync.
require 'fileutils'
require 'open3'
require 'pathname'
require 'digest'

module HfSnapshot
  FILES = %w[Dockerfile .dockerignore README.md LICENSE Cargo.toml Cargo.lock].freeze
  TREES = %w[web crates benches native/piper-runtime native/vendor/piper-rs native/vendor/espeak-rs native/vendor/espeak-rs-sys].freeze

  def self.command!(*argv, chdir:)
    output, status = Open3.capture2e(*argv, chdir: chdir)
    raise "#{argv.first} failed (#{status.exitstatus}): #{output}" unless status.success?
    output
  end

  def self.create(source, destination)
    source = File.realpath(source)
    destination = File.expand_path(destination)
    raise 'Snapshot must be outside the source repository' if destination == source || destination.start_with?("#{source}/")
    raise 'Snapshot destination must be empty' if File.exist?(destination) && !Dir.empty?(destination)
    FileUtils.mkdir_p(destination)
    paths = command!('git', 'ls-files', '-z', chdir: source).split("\0").select do |path|
      FILES.include?(path) || TREES.any? { |tree| path.start_with?("#{tree}/") }
    end
    %w[Dockerfile README.md Cargo.toml Cargo.lock web/package.json web/src/wasm/converter_wasm_bg.wasm].each do |path|
      raise "Missing required tracked input: #{path}" unless paths.include?(path)
    end
    binaries = []
    paths.each do |path|
      input = File.join(source, path)
      raise "Unsafe snapshot input: #{path}" unless Pathname.new(path).cleanpath.to_s == path && !path.start_with?('/') && File.file?(input) && !File.symlink?(input)
      bytes = File.binread(input)
      raise "Unresolved LFS pointer: #{path}" if bytes.start_with?("version https://git-lfs.github.com/spec/v1\n")
      raise "Model weights must not enter the snapshot: #{path}" if File.extname(path).downcase == '.onnx'
      output = File.join(destination, path)
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.copy_file(input, output)
      binaries << path if bytes.include?("\0") || !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end
    command!('git', 'init', '--initial-branch=master', chdir: destination)
    command!('git', 'config', 'user.name', 'hf-sync-bot', chdir: destination)
    command!('git', 'config', 'user.email', 'hf-sync-bot@users.noreply.github.com', chdir: destination)
    command!('git', 'lfs', 'install', '--local', chdir: destination)
    binaries.each { |path| command!('git', 'lfs', 'track', '--filename', path, chdir: destination) }
    command!('git', 'add', '-A', chdir: destination)
    command!('git', 'commit', '-m', 'HF runtime snapshot', chdir: destination)
    binaries.each do |path|
      pointer = command!('git', 'show', "HEAD:#{path}", chdir: destination)
      digest = Digest::SHA256.file(File.join(destination, path)).hexdigest
      expected = "version https://git-lfs.github.com/spec/v1\noid sha256:#{digest}\nsize #{File.size(File.join(destination, path))}\n"
      raise "Binary was not stored as an exact LFS pointer: #{path}" unless pointer == expected
    end
    puts "HF snapshot prepared: #{paths.length} tracked inputs; #{binaries.length} LFS binaries"
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: hf_snapshot.rb SOURCE EMPTY_DESTINATION' unless ARGV.length == 2
  begin
    HfSnapshot.create(*ARGV)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
