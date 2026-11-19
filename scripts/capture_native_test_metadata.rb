# frozen_string_literal: true

# Capture sanitized existing build metadata; never establish runtime eligibility.

require "digest"
require "etc"
require_relative "native_test_metadata_plist"
require_relative "python_cli_compat"
require_relative "python_json"

module CaptureNativeTestMetadata
  class Blocked < StandardError; end

  Plist = NativeTestMetadataPlist
  MAX_MANIFESTS = 8
  MAX_MANIFEST_BYTES = 1024 * 1024
  MAX_INFOS = 32
  MAX_INFO_BYTES = 256 * 1024
  MAX_NODES = 2048
  MAX_DEPTH = 12
  MAX_OUTPUT_BYTES = 4 * 1024 * 1024
  APPLE_DOCTYPE = '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'.b
  PATH_FIELDS = %w[TestHostPath TestBundlePath UITargetAppPath].freeze
  STRUCTURES = %w[TestConfigurations TestTargets __xctestrun_metadata__].freeze
  TARGETS = %w[EpubToMp3Tests EpubToMp3UITests].freeze
  INFO_STRINGS = %w[CFBundleIdentifier CFBundleExecutable CFBundlePackageType DTXcode DTXcodeBuild DTPlatformName
                    DTPlatformVersion DTSDKName DTSDKBuild MinimumOSVersion LSMinimumSystemVersion].freeze
  BLOCKED_MESSAGE = "Native test metadata capture blocked; no runtime eligibility established."
  PROG = "capture_native_test_metadata.rb"
  OPTIONS = { "--products" => :products, "--output" => :output, "--xcode-version-file" => :xcode_version_file }.freeze
  LINUX_DIRECTORY = RUBY_PLATFORM.match?(/aarch64|arm/) ? 0o40000 : 0o200000
  O_DIRECTORY = if File.const_defined?(:DIRECTORY) then File::DIRECTORY
                elsif RUBY_PLATFORM.include?("darwin") then 0x100000
                elsif RUBY_PLATFORM.include?("linux") then LINUX_DIRECTORY
                else File::NONBLOCK
                end
  DIRECTORY_FLAGS = File::RDONLY | O_DIRECTORY | File::NOFOLLOW
  # Python OSError/UnicodeError/ValueError/TypeError/RecursionError equivalents.
  UNREADABLE = [SystemCallError, IOError, EncodingError, ArgumentError, TypeError, Plist::Recursion, SystemStackError].freeze

  module_function

  def components(value)
    raise Blocked, "invalid_path" if !value.is_a?(String) || value.empty? || value.length > 4096
    raise Blocked, "invalid_path" if value.b.match?(/[\x00-\x1f\x7f]/n)

    parts = value.split("/", -1)
    raise Blocked, "path_escape" if parts.any? { |part| ["", ".", ".."].include?(part) }

    parts
  end

  # Path(value).absolute(): join cwd, drop "." and empty parts, keep POSIX "//".
  def absolute(value)
    value = "#{Dir.pwd}/#{value}" unless value.start_with?("/")
    anchor = value.start_with?("//") && !value.start_with?("///") ? "//" : "/"
    path = anchor + value.split("/").reject { |part| part.empty? || part == "." }.join("/")
    components(path[1..])
    path
  end

  def relative_to(path, base)
    return "." if path == base
    raise ArgumentError, "not relative" unless path.start_with?("#{base}/")

    path.delete_prefix("#{base}/")
  end

  def home
    @home ||= File.open(".", File::RDONLY)
  end

  # Runs the block with the process cwd at the descriptor (openat/fstatat emulation).
  def at(descriptor)
    origin = home
    Dir.fchdir(descriptor.fileno)
    yield
  ensure
    Dir.fchdir(origin.fileno) if origin
  end

  def open_directory(name)
    descriptor = File.open(name, DIRECTORY_FLAGS)
    return descriptor if descriptor.stat.directory?

    descriptor.close
    raise Errno::ENOTDIR, name
  end

  def child_directory(root, parts, create: false)
    descriptor = root.dup
    parts.each do |part|
      following = at(descriptor) do
        begin
          Dir.mkdir(part, 0o700) if create
        rescue Errno::EEXIST
          nil
        end
        open_directory(part)
      end
      descriptor.close
      descriptor = following
    end
    descriptor
  rescue Exception # rubocop:disable Lint/RescueException
    descriptor.close if descriptor && !descriptor.closed?
    raise
  end

  def directory(path, create: false)
    descriptor = File.open("/", File::RDONLY | O_DIRECTORY)
    begin
      child_directory(descriptor, components(path[1..]), create: create)
    ensure
      descriptor.close
    end
  end

  def identity(metadata)
    [metadata.dev, metadata.ino, metadata.mode, metadata.size, metadata.mtime.tv_sec, metadata.mtime.tv_nsec,
     metadata.ctime.tv_sec, metadata.ctime.tv_nsec]
  end

  def read_chunk(descriptor, length)
    descriptor.sysread(length)
  rescue EOFError
    "".b
  end

  def read_regular(root, relative, limit)
    parts = components(relative)
    parent = child_directory(root, parts[0...-1])
    descriptor = nil
    begin
      before = at(parent) { File.lstat(parts[-1]) }
      raise Blocked, "nonregular_or_oversized_input" if !before.file? || before.size > limit

      descriptor = at(parent) { File.open(parts[-1], File::RDONLY | File::NOFOLLOW | File::BINARY) }
      raise Blocked, "input_replaced" if identity(descriptor.stat) != identity(before)

      chunks = []
      remaining = limit + 1
      while remaining.positive?
        chunk = read_chunk(descriptor, [65_536, remaining].min)
        break if chunk.empty?

        chunks << chunk
        remaining -= chunk.bytesize
      end
      data = chunks.join.b
      raise Blocked, "input_changed" if data.bytesize > limit || identity(descriptor.stat) != identity(before)

      current_parent = child_directory(root, parts[0...-1])
      begin
        after = at(current_parent) { File.lstat(parts[-1]) }
        raise Blocked, "input_replaced" if identity(current_parent.stat) != identity(parent.stat) || identity(after) != identity(before)
      ensure
        current_parent.close
      end
      data
    ensure
      descriptor&.close
      parent.close
    end
  end

  def parse_plist(data)
    parse_data = data
    unless data.start_with?("bplist")
      # Remove only Apple's exact standard declaration before parsing. No DTD
      # or entity declaration reaches the XML parser, and no resolver is used.
      index = data.index(APPLE_DOCTYPE)
      parse_data = index ? data.byteslice(0, index) + data.byteslice((index + APPLE_DOCTYPE.bytesize)..) : data
      declarations = parse_data.upcase
      if data.include?("\0") || declarations.include?("<!ENTITY") || declarations.include?("<!DOCTYPE")
        raise Blocked, "xml_declarations_not_supported"
      end
    end
    begin
      result = Plist.load(parse_data)
    rescue Plist::Invalid
      raise Blocked, "invalid_plist"
    end
    raise Blocked, "plist_root_not_object" unless result.is_a?(Hash)

    result
  end

  def bundle_name?(name) = name.end_with?(".app", ".xctest")

  def inventory(root)
    manifests = []
    infos = []
    pending = [[[], root.dup]]
    nodes = 0
    begin
      until pending.empty?
        parts, descriptor = pending.pop
        begin
          raise Blocked, "inventory_budget_exceeded" if parts.length > MAX_DEPTH

          at(descriptor) { Dir.children(".") }.each do |name|
            nodes += 1
            raise Blocked, "inventory_budget_exceeded" if nodes > MAX_NODES || parts.length > MAX_DEPTH

            relative = [*parts, name].join("/")
            components(relative)
            if name.end_with?(".xctestrun")
              manifests << relative
              raise Blocked, "manifest_count_exceeded" if manifests.length > MAX_MANIFESTS
            elsif name == "Info.plist" && parts.any? { |part| bundle_name?(part) }
              infos << relative
              raise Blocked, "bundle_count_exceeded" if infos.length > MAX_INFOS
            else
              metadata = begin
                at(descriptor) { File.lstat(name) }
              rescue Errno::ENOENT
                nil
              end
              if metadata&.directory?
                next if %w[Resources Frameworks models].include?(name) || name.end_with?(".dSYM", ".swiftmodule")

                pending << [[*parts, name], child_directory(root, [*parts, name])]
              elsif metadata&.symlink? && bundle_name?(name)
                raise Blocked, "symlink_bundle"
              end
            end
          end
        ensure
          descriptor.close
        end
      end
    ensure
      pending.each { |_, descriptor| descriptor.close }
    end
    [manifests.sort, infos.sort]
  end

  def validate_reference(root, relative)
    parts = components(relative)
    parent = child_directory(root, parts[0...-1])
    begin
      metadata = at(parent) { File.lstat(parts[-1]) }
      raise Blocked, "unsafe_bundle_reference" unless metadata.directory? || metadata.file?
    ensure
      parent.close
    end
  end

  # Python `child in TARGETS` raises TypeError for unhashable list/dict values.
  def target_name?(child)
    raise TypeError, "unhashable type" if child.is_a?(Array) || child.is_a?(Hash)

    TARGETS.include?(child)
  end

  def sanitize_manifest(value, products, descriptor)
    state = { redacted: 0, nodes: 0, paths: [] }
    sanitized = visit(value, [], 0, state, products, descriptor)
    [Plist.dump_binary(sanitized), state[:paths], state[:redacted]]
  end

  def visit(item, position, depth, state, products, descriptor)
    state[:nodes] += 1
    raise Blocked, "manifest_structure_budget_exceeded" if state[:nodes] > MAX_NODES || depth > MAX_DEPTH
    return item.each_with_index.map { |child, index| visit(child, [*position, index], depth + 1, state, products, descriptor) } if item.is_a?(Array)

    unless item.is_a?(Hash)
      state[:redacted] += 1
      return {}
    end
    result = {}
    item.each do |key, child|
      if STRUCTURES.include?(key) || (position.empty? && TARGETS.include?(key))
        raise Blocked, "invalid_structural_type" unless child.is_a?(Hash) || child.is_a?(Array)

        result[key] = visit(child, [*position, key], depth + 1, state, products, descriptor)
      elsif key == "FormatVersion" && child.is_a?(Integer) && child.between?(0, 100)
        result[key] = child
      elsif %w[IsUITestBundle IsAppHostedTestBundle].include?(key) && [true, false].include?(child)
        result[key] = child
      elsif %w[BlueprintName ProductModuleName TestTargetName].include?(key) && target_name?(child)
        result[key] = child
      elsif PATH_FIELDS.include?(key) && child.is_a?(String)
        sanitize_path(key, child, position, result, state, products, descriptor)
      else
        state[:redacted] += 1
      end
    end
    result
  end

  def sanitize_path(key, child, position, result, state, products, descriptor)
    if child.start_with?("/")
      absolute_path = absolute(child)
      relative = begin
        relative_to(absolute_path, products)
      rescue ArgumentError
        raise Blocked, "absolute_reference_outside_products"
      end
      validate_reference(descriptor, relative)
      state[:paths] << { "field" => [*position, key], "original_form" => "absolute_products",
                         "products_relative" => relative, "observed_type" => "string" }
      state[:redacted] += 1
    elsif child.start_with?("__TESTROOT__/")
      validate_reference(descriptor, child.delete_prefix("__TESTROOT__/"))
      result[key] = child
    elsif child.start_with?("__TESTHOST__/")
      components(child.delete_prefix("__TESTHOST__/"))
      result[key] = child
    elsif !child.include?("$") && !child.include?("__")
      validate_reference(descriptor, child)
      result[key] = child
    else
      state[:redacted] += 1
    end
  end

  def sanitize_info(value)
    result = {}
    value.each do |key, item|
      if INFO_STRINGS.include?(key) && item.is_a?(String) && item.match?(/\A[A-Za-z0-9_.+\-]{1,255}\z/)
        result[key] = item
      elsif key == "CFBundleSupportedPlatforms" && item.is_a?(Array) && item.length <= 4 &&
            item.all? { |name| name.is_a?(String) && %w[MacOSX iPhoneSimulator iPhoneOS].include?(name) }
        result[key] = item
      end
    end
    result
  end

  def host_platform
    uname = Etc.uname
    [uname[:sysname], uname[:machine]]
  end

  def source_receipt(environment)
    result = {}
    %w[CHECKOUT_SHA TREE_SHA PR_HEAD_SHA EVENT_SHA WORKFLOW_SHA].each do |key|
      value = environment.fetch("INVENTORY_#{key}", "")
      if key == "PR_HEAD_SHA" && value.empty?
        result[key.downcase] = nil
      elsif value.match?(/\A[0-9a-f]{40}\z/)
        result[key.downcase] = value
      else
        raise Blocked, "invalid_source_identity"
      end
    end
    state = environment.fetch("INVENTORY_WORKTREE_STATE", "unknown")
    raise Blocked, "invalid_worktree_state" unless %w[clean dirty unknown].include?(state)

    result["worktree_state"] = state
    %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT].each do |key|
      value = environment.fetch(key, "")
      raise Blocked, "invalid_run_identity" unless value.match?(/\A[1-9][0-9]{0,19}\z/)

      result[key.downcase] = value
    end
    raise Blocked, "invalid_job_identity" unless environment["GITHUB_JOB"] == "macos-preferences"

    arch = environment["EXPECTED_ARCH"]
    raise Blocked, "invalid_architecture" unless %w[arm64 x86_64].include?(arch)

    host_os, host_arch = host_platform
    result.merge!("job_key" => "macos-preferences", "architecture" => arch,
                  "observed_host_os" => %w[Darwin Linux Windows].include?(host_os) ? host_os : "unknown",
                  "observed_host_arch" => %w[arm64 x86_64 aarch64].include?(host_arch) ? host_arch : "unknown")
  end

  def write_output(descriptor, name, data, budget)
    budget[0] += data.bytesize
    raise Blocked, "output_budget_exceeded" if budget[0] > MAX_OUTPUT_BYTES

    flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY
    at(descriptor) { File.open(name, flags, 0o600) { |stream| stream.write(data) } }
  end

  def capture(args, environment)
    out = root = output = nil
    receipt = { "schema_version" => 1, "capture_state" => "blocked", "runtime_eligibility" => "unverified",
                "manifests" => [], "bundles" => [] }
    budget = [0]
    status = 2
    begin
      products = absolute(args[:products])
      output = absolute(args[:output])
      if output == products || output.start_with?("#{products}/") || products.start_with?("#{output}/")
        raise Blocked, "overlapping_input_output"
      end

      output_parent = File.dirname(output)
      parent = directory(output_parent, create: true)
      begin
        at(parent) { Dir.mkdir(File.basename(output), 0o700) }
        out = child_directory(parent, [File.basename(output)])
      ensure
        parent.close
      end
      receipt["source"] = source_receipt(environment)
      version_path = absolute(args[:xcode_version_file])
      version_parent = directory(File.dirname(version_path))
      begin
        version = read_regular(version_parent, File.basename(version_path), 4096)
      ensure
        version_parent.close
      end
      raise EncodingError, "ascii" unless version.ascii_only?

      match = version.force_encoding(Encoding::UTF_8).match(/\AXcode (16\.4)\nBuild version (16F6)\n?\z/)
      raise Blocked, "unsupported_xcode_receipt" unless match

      receipt["xcode"] = { "version" => match[1], "build" => match[2] }
      begin
        root = directory(products)
      rescue Errno::ENOENT
        receipt["capture_state"] = "missing_manifest"
        status = 0
      else
        manifests, infos = inventory(root)
        manifests.each_with_index do |relative, index|
          original = read_regular(root, relative, MAX_MANIFEST_BYTES)
          sanitized, paths, redactions = sanitize_manifest(parse_plist(original), products, root)
          name = "manifest-#{index}.sanitized.plist"
          write_output(out, name, sanitized, budget)
          receipt["manifests"] << { "sanitized_file" => name, "original_bytes" => original.bytesize,
                                    "original_sha256" => Digest::SHA256.hexdigest(original),
                                    "sanitized_sha256" => Digest::SHA256.hexdigest(sanitized),
                                    "path_sidecar" => paths, "redacted_fields" => redactions }
        end
        infos.each do |relative|
          original = read_regular(root, relative, MAX_INFO_BYTES)
          receipt["bundles"] << { "products_relative" => relative, "original_sha256" => Digest::SHA256.hexdigest(original),
                                  "allowed_info" => sanitize_info(parse_plist(original)) }
        end
        current = directory(products)
        begin
          raise Blocked, "products_replaced" if identity(current.stat) != identity(root.stat)
        ensure
          current.close
        end
        receipt["capture_state"] = manifests.empty? ? "missing_manifest" : "captured"
        status = 0
      end
    rescue Blocked => error
      receipt["blocked_reason"] = error.message
    rescue *UNREADABLE
      receipt["blocked_reason"] = "unreadable_or_unsafe_metadata"
    ensure
      root&.close
      if out
        begin
          current = directory(output)
          begin
            raise Blocked, "output_replaced" if identity(current.stat) != identity(out.stat)
          ensure
            current.close
          end
          write_output(out, "receipt.json", PythonJson.dump(receipt, indent: 2, sort_keys: true).b, budget)
        rescue Blocked, SystemCallError, IOError
          status = 2
        end
        out.close
      end
    end
    warn BLOCKED_MESSAGE unless status.zero?
    status
  end

  USAGE = <<~TEXT
    usage: #{PROG} [-h] --products PRODUCTS
                                           --output OUTPUT
                                           --xcode-version-file XCODE_VERSION_FILE
  TEXT
  HELP = <<~TEXT
    #{USAGE}
    Capture sanitized existing build metadata; never establish runtime
    eligibility.

    options:
      -h, --help            show this help message and exit
      --products PRODUCTS
      --output OUTPUT
      --xcode-version-file XCODE_VERSION_FILE
  TEXT

  def main(argv = ARGV, environment = ENV)
    parser = PythonCliCompat::ArgumentParser.new(
      prog: PROG, usage: USAGE, help: HELP,
      options: OPTIONS.to_h { |option, dest| [option, { dest: dest, kind: :value, required: true }] }
    )
    capture(parser.parse(argv), environment)
  end
end

exit CaptureNativeTestMetadata.main if $PROGRAM_NAME == __FILE__
