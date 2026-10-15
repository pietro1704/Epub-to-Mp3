#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "digest"
require "base64"
require "tempfile"
require "pathname"

# Optimistic worktree baselines plus Git's own exclusive index lock. This cannot
# prevent an editor or an uncooperative process from changing files afterward.
class ScopedGitIndex
  class Error < StandardError; end

  def initialize
    @environment = ENV.keys.grep(/^GIT_/).to_h { |key| [key, nil] }
    @root = File.realpath(git("rev-parse", "--show-toplevel").strip)
    @git_dir = File.realpath(git("rev-parse", "--absolute-git-dir").strip)
    @index = File.expand_path(git("rev-parse", "--git-path", "index").strip, @root)
  end

  def git(*args, index: nil, input: nil, allow_failure: false)
    environment = @environment.merge("GIT_INDEX_FILE" => index, "GIT_OPTIONAL_LOCKS" => "0", "GIT_LITERAL_PATHSPECS" => "1")
    out, err, status = Open3.capture3(environment, "git", "--no-optional-locks", *args,
                                     stdin_data: input || "", chdir: @root || Dir.pwd)
    raise Error, "Git command failed (#{status.exitstatus}): #{args.first}: #{err.strip}" unless status.success? || allow_failure
    status.success? ? out : nil
  end

  def identity
    { "root" => @root, "git_dir" => @git_dir, "index" => @index,
      "head_ref" => git("symbolic-ref", "--quiet", "HEAD", allow_failure: true)&.strip,
      "head" => git("rev-parse", "--verify", "HEAD", allow_failure: true)&.strip }
  end

  def digest(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def index_digest
    File.exist?(@index) ? digest(File.binread(@index)) : nil
  end

  def validate_path(path)
    parts = path.split("/", -1)
    unless !path.empty? && !Pathname.new(path).absolute? && parts.none? { |part| ["", ".", ".."].include?(part) || part.downcase == ".git" }
      raise Error, "Invalid scoped path: #{path.inspect}"
    end
    parts[0...-1].inject(@root) do |parent, part|
      parent = File.join(parent, part)
      raise Error, "Symlink ancestor is not allowed: #{path.inspect}" if File.symlink?(parent)
      parent
    end
    raise Error, "Directories are not scoped files: #{path.inspect}" if File.directory?(File.join(@root, path)) && !File.symlink?(File.join(@root, path))
    path
  end

  def state(path)
    info = File.lstat(path)
    if info.symlink?
      { "kind" => "symlink", "sha256" => digest(File.readlink(path)) }
    elsif info.file?
      { "kind" => "file", "mode" => info.mode & 0o777, "sha256" => digest(File.binread(path)) }
    else
      raise Error, "Unsupported file type: #{path.inspect}"
    end
  rescue Errno::ENOENT
    { "kind" => "absent" }
  end

  def states(paths)
    paths.to_h { |path| [path, state(File.join(@root, validate_path(path)))] }
  end

  def candidate
    Tempfile.create(["scoped-index-", ".index"], File.dirname(@index)) do |file|
      path = file.path
      if File.exist?(@index)
        file.binmode
        file.write(File.binread(@index))
        file.flush
      else
        file.close
        File.unlink(path)
        git("read-tree", "--empty", index: path)
      end
      yield path
    ensure
      File.unlink("#{path}.lock") if path && File.exist?("#{path}.lock")
      File.unlink(path) if path && File.exist?(path)
    end
  end

  def image(index)
    bytes = File.binread(index)
    { "bytes" => Base64.strict_encode64(bytes), "sha256" => digest(bytes),
      "entries" => Base64.strict_encode64(git("ls-files", "--stage", "-z", index: index)) }
  end

  def populate(index, operation, paths, files, sources)
    # Rebuild from clean HEAD, never from a manifest-provided image or the
    # currently staged index. Prepared source bytes remain the reviewed input.
    git("read-tree", "--empty", index: index)
    if git("rev-parse", "--verify", "HEAD", allow_failure: true)
      git("read-tree", "HEAD", index: index)
    end
    if operation == "untrack"
      git("rm", "--cached", "--quiet", "--ignore-unmatch", "--", *paths, index: index)
      return
    end
    ordinary = paths - sources.keys
    git("add", "--", *ordinary, index: index) unless ordinary.empty?
    sources.each do |path, source|
      oid = git("hash-object", "-w", "--stdin", input: File.binread(source.fetch("path"))).strip
      original = files.fetch(path)
      raise Error, "Prepared destination must be a regular file or absent" unless %w[file absent].include?(original.fetch("kind"))
      mode = original.fetch("mode", 0o644) & 0o111 == 0 ? "100644" : "100755"
      git("update-index", "--add", "--cacheinfo", mode, oid, path, index: index)
    end
  end

  def capture(manifest_path, paths, prepared)
    raise Error, "Scope must contain at least one unique file" if paths.empty? || paths.uniq != paths
    paths.each { |path| validate_path(path) }
    raise Error, "Prepared destinations must belong to the scope" unless (prepared.keys - paths).empty?
    raise Error, "Preexisting staged changes must be resolved before capture" unless git("diff", "--cached", "--name-only", "-z").empty?
    baseline = identity
    original_index = index_digest
    files = states(paths)
    sources = prepared.to_h do |path, source|
      source = File.expand_path(source)
      raise Error, "Prepared source must be a regular file" unless File.file?(source) && !File.symlink?(source)
      [path, { "path" => source, "state" => state(source) }]
    end
    images = {}
    %w[stage untrack].each do |operation|
      candidate do |index|
        populate(index, operation, paths, files, sources)
        images[operation] = image(index)
      end
    end
    manifest = { "version" => 1, "identity" => baseline, "index_sha256" => original_index,
                 "paths" => paths, "files" => files, "sources" => sources, "images" => images }
    validate_baseline(manifest)
    raise Error, "Index changed during capture" unless index_digest == original_index
    # O_EXCL makes capture immutable. Keep manifests outside their own scope.
    raise Error, "Manifest cannot be a scoped destination or prepared source" if (paths.map { |p| File.join(@root, p) } + sources.values.map { |s| s.fetch("path") }).include?(File.expand_path(manifest_path))
    File.open(manifest_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(manifest) + "\n")
      file.flush
      file.fsync
    end
    puts "Captured #{paths.length} scoped paths; real index and worktree unchanged."
  end

  def load_manifest(path)
    manifest = JSON.parse(File.binread(path))
    raise Error, "Unsupported manifest version" unless manifest.fetch("version") == 1
    paths = manifest.fetch("paths")
    raise Error, "Invalid manifest scope" unless paths.is_a?(Array) && !paths.empty? && paths.uniq == paths && paths.all? { |p| p.is_a?(String) }
    paths.each { |p| validate_path(p) }
    raise Error, "Manifest file scope mismatch" unless manifest.fetch("files").keys.sort == paths.sort
    raise Error, "Prepared source scope mismatch" unless (manifest.fetch("sources").keys - paths).empty?
    manifest
  end

  def validate_baseline(manifest)
    raise Error, "Repository identity or HEAD changed" unless identity == manifest.fetch("identity")
    raise Error, "Scoped worktree changed since capture" unless states(manifest.fetch("paths")) == manifest.fetch("files")
    manifest.fetch("sources").each_value do |source|
      raise Error, "Prepared source changed since capture" unless state(source.fetch("path")) == source.fetch("state")
    end
  end

  def validate_image(manifest, operation)
    image = manifest.fetch("images").fetch(operation)
    bytes = Base64.strict_decode64(image.fetch("bytes"))
    raise Error, "Candidate index checksum mismatch" unless digest(bytes) == image.fetch("sha256")
    candidate do |index|
      File.binwrite(index, bytes)
      raise Error, "Candidate index entries mismatch" unless git("ls-files", "--stage", "-z", index: index) == Base64.strict_decode64(image.fetch("entries"))
      changed = git("diff", "--cached", "--name-only", "--no-renames", "-z", index: index).split("\0")
      raise Error, "Candidate index exceeds captured scope" unless (changed - manifest.fetch("paths")).empty?
      git("diff", "--cached", "--check", index: index)
      populate(index, operation, manifest.fetch("paths"), manifest.fetch("files"), manifest.fetch("sources"))
      unless git("ls-files", "--stage", "-z", index: index) == Base64.strict_decode64(image.fetch("entries"))
        raise Error, "Candidate contents do not match validated worktree and prepared sources"
      end
    end
    bytes
  end

  def apply(manifest, operation)
    lock_path = "#{@index}.lock"
    lock = nil
    begin
      lock = File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      validate_baseline(manifest)
      raise Error, "Index changed since capture" unless index_digest == manifest.fetch("index_sha256")
      bytes = validate_image(manifest, operation)
      validate_baseline(manifest)
      raise Error, "Index changed during transaction" unless index_digest == manifest.fetch("index_sha256")
      lock.binmode
      lock.write(bytes)
      lock.flush
      lock.fsync
      File.rename(lock_path, @index)
      installed = true
      puts "Applied #{operation} for #{manifest.fetch('paths').length} scoped paths; worktree unchanged."
    ensure
      if lock
        File.unlink(lock_path) if !installed && File.exist?(lock_path) && File.stat(lock_path).ino == lock.stat.ino
        lock.close
      end
    end
  end

  def verify(manifest)
    lock_path = "#{@index}.lock"
    lock = nil
    begin
      lock = File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      validate_baseline(manifest)
      before = index_digest
      entries = git("ls-files", "--stage", "-z")
      operation = %w[stage untrack].find do |name|
        entries == Base64.strict_decode64(manifest.fetch("images").fetch(name).fetch("entries"))
      end
      raise Error, "Staged index does not match captured scope" unless operation
      validate_image(manifest, operation)
      validate_baseline(manifest)
      raise Error, "Index changed during verification" unless before == index_digest
      puts "Verified #{operation}: exact captured index entries and unchanged scoped bytes."
    ensure
      if lock
        File.unlink(lock_path) if File.exist?(lock_path) && File.stat(lock_path).ino == lock.stat.ino
        lock.close
      end
    end
  end

  def self.run(args)
    operation, manifest_path, *rest = args
    raise Error, "Usage: scoped_git_index.rb capture MANIFEST [--stage-from DEST SOURCE] -- PATH... | stage|untrack|verify MANIFEST" unless %w[capture stage untrack verify].include?(operation) && manifest_path
    tool = new
    if operation == "capture"
      prepared = {}
      while rest.first == "--stage-from"
        _, dest, source = rest.shift(3)
        raise Error, "Invalid or duplicate --stage-from" unless dest && source && !prepared.key?(dest)
        prepared[dest] = source
      end
      raise Error, "Capture requires -- before exact paths" unless rest.shift == "--"
      tool.capture(manifest_path, rest, prepared)
    else
      raise Error, "Unexpected arguments" unless rest.empty?
      manifest = tool.load_manifest(manifest_path)
      operation == "verify" ? tool.verify(manifest) : tool.apply(manifest, operation)
    end
  rescue Error, KeyError, TypeError, ArgumentError, SystemCallError, JSON::ParserError => error
    warn "Scoped Git index rejected: #{error.message}"
    1
  else
    0
  end
end

exit ScopedGitIndex.run(ARGV) if $PROGRAM_NAME == __FILE__
