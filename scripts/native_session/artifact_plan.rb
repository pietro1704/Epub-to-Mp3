# frozen_string_literal: true

module NativeSimulatorSession
  class Plan
    DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-SE"
    RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-15-5"
    XCODE = "/Applications/Xcode-16.4.0.app/Contents/Developer"
    CHUNK_BYTES = 65_536
    VALIDATION_SECONDS = 5.0
    # The test host is still a regular-file fixture, not an admitted native app.
    FILE_LIMITS = { "plan" => 65_536, "xctestrun" => 4 * 1024**2,
                    "source" => 1024**2, "monitor" => 256 * 1024,
                    "test_host" => 4 * 1024**2 }.freeze
    TOTAL_BYTES = FILE_LIMITS.values.sum
    attr_reader :data

    def self.checkpoint!(deadline, progress)
      raise Stop, "Artifact validation deadline exceeded" if NativeSimulatorSession.now >= deadline
      progress&.call
      raise Stop, "Artifact validation deadline exceeded" if NativeSimulatorSession.now >= deadline
    end

    def self.metadata(stat)
      [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime]
    end

    def self.read_identity(path, limit:, deadline:, progress: nil, capture: false)
      checkpoint!(deadline, progress)
      expanded = File.expand_path(path)
      raise Stop, "Identity path must be canonical" unless File.realpath(expanded) == expanded
      before = File.lstat(expanded)
      raise Stop, "Identity must be a regular file" unless before.file?
      raise Stop, "Artifact exceeds size limit" if before.size > limit
      unless File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)
        raise Stop, "Nonblocking no-follow artifact reads unavailable"
      end
      checkpoint!(deadline, progress)
      digest = Digest::SHA256.new
      bytes = 0
      contents = +"" if capture
      File.open(expanded, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        opened = file.stat
        unless opened.file? && metadata(opened) == metadata(before)
          raise Stop, "Identity changed before reading"
        end
        loop do
          checkpoint!(deadline, progress)
          chunk = file.read([CHUNK_BYTES, limit + 1 - bytes].min)
          checkpoint!(deadline, progress)
          break unless chunk
          bytes += chunk.bytesize
          raise Stop, "Artifact exceeds size limit" if bytes > limit
          digest.update(chunk)
          contents << chunk if capture
        end
        checkpoint!(deadline, progress)
        unless bytes == before.size && metadata(file.stat) == metadata(before) &&
               File.realpath(expanded) == expanded && metadata(File.lstat(expanded)) == metadata(before)
          raise Stop, "Identity changed while hashing"
        end
      end
      [[expanded, *metadata(before), digest.hexdigest], contents]
    rescue SystemCallError => error
      raise Stop, "Cannot read artifact identity (#{error.class})"
    end

    def initialize(path)
      @path = File.expand_path(path)
      deadline = NativeSimulatorSession.now + VALIDATION_SECONDS
      @plan_identity, contents = self.class.read_identity(@path, limit: FILE_LIMITS.fetch("plan"), deadline: deadline, capture: true)
      @data = JSON.parse(contents, freeze: true)
      expected = %w[schema_version device xcode_path xcode_version source_revision source_root files tests duration_seconds phase_timeout_seconds cleanup_timeout_seconds]
      raise Stop, "Unknown or missing session fields" unless @data.is_a?(Hash) && @data.keys.sort == expected.sort
      target = @data.fetch("device")
      unless @data["schema_version"] == 1 && target.is_a?(Hash) && target.keys.sort == %w[uuid name device_type runtime].sort &&
             target["uuid"].is_a?(String) && target["uuid"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i) &&
             target["name"] == "iPhone SE" && target["device_type"] == DEVICE_TYPE && target["runtime"] == RUNTIME &&
             @data["xcode_path"] == XCODE && @data["xcode_version"] == "16.4" &&
             @data["source_revision"].is_a?(String) && @data["source_revision"].match?(/\A[0-9a-f]{40}\z/)
        raise Stop, "Session requires exact SE1/iOS15.5/Xcode16.4 identity"
      end
      %w[duration_seconds phase_timeout_seconds cleanup_timeout_seconds].each do |key|
        value = @data[key]
        raise Stop, "Invalid session deadline" unless value.is_a?(Numeric) && value.finite? && value.positive? && value <= 300
      end
      unless @data["cleanup_timeout_seconds"] < @data["duration_seconds"] && @data["phase_timeout_seconds"] <= @data["duration_seconds"]
        raise Stop, "Cleanup requires a reserved session budget"
      end
      tests = @data["tests"]
      unless tests.is_a?(Array) && tests.length.between?(1, 20) && tests.uniq == tests &&
             tests.all? { |test| test.is_a?(String) && test.match?(/\AEpubToMp3(?:UI)?Tests\/[A-Za-z_]\w*(?:\/[A-Za-z_]\w*)?\z/) }
        raise Stop, "Session requires explicit native test identifiers"
      end
      root = @data["source_root"]
      raise Stop, "Source root must be canonical" unless root.is_a?(String) && File.realpath(root) == root && File.directory?(root)
      root_stat = File.lstat(root)
      @root_identity = [root_stat.dev, root_stat.ino]
      files = @data["files"]
      raise Stop, "Missing immutable session artifacts" unless files.is_a?(Hash) && files.keys.sort == %w[source test_host xctestrun monitor].sort
      files.each_value do |entry|
        unless entry.is_a?(Hash) && entry.keys.sort == %w[path sha256] && entry["path"].is_a?(String) && entry["path"].start_with?(root + "/") &&
               entry["sha256"].is_a?(String) && entry["sha256"].match?(/\A[0-9a-f]{64}\z/)
          raise Stop, "Invalid artifact identity"
        end
      end
      verify_sizes!(deadline: deadline)
      @identities = files.to_h do |role, entry|
        identity, = self.class.read_identity(entry["path"], limit: FILE_LIMITS.fetch(role), deadline: deadline)
        raise Stop, "Artifact SHA256 mismatch" unless identity.last == entry["sha256"]
        [role, identity]
      end
      verify!(deadline: deadline)
    end

    def [](key)
      @data.fetch(key)
    end

    def verify_sizes!(deadline: NativeSimulatorSession.now + VALIDATION_SECONDS, progress: nil)
      total = File.lstat(@path).size
      self["files"].each do |role, entry|
        self.class.checkpoint!(deadline, progress)
        stat = File.lstat(entry.fetch("path"))
        raise Stop, "Identity must be a regular file" unless stat.file?
        raise Stop, "Artifact exceeds size limit" if stat.size > FILE_LIMITS.fetch(role)
        total += stat.size
      end
      raise Stop, "Session artifact budget exceeded" if total > TOTAL_BYTES
    end

    def verify!(deadline: NativeSimulatorSession.now + VALIDATION_SECONDS, progress: nil)
      identity, = self.class.read_identity(@path, limit: FILE_LIMITS.fetch("plan"), deadline: deadline, progress: progress)
      raise Stop, "Plan identity changed" unless identity == @plan_identity
      root = File.lstat(self["source_root"])
      raise Stop, "Source root identity changed" unless root.directory? && [root.dev, root.ino] == @root_identity && File.realpath(self["source_root"]) == self["source_root"]
      verify_sizes!(deadline: deadline, progress: progress)
      xml = nil
      @identities.each do |role, expected|
        observed, contents = self.class.read_identity(expected.first, limit: FILE_LIMITS.fetch(role), deadline: deadline,
          progress: progress, capture: role == "xctestrun")
        raise Stop, "Artifact identity changed" unless observed == expected
        xml = contents if role == "xctestrun"
      end
      xml_path = self["files"].fetch("xctestrun").fetch("path")
      raise Stop, "xctestrun entities are not accepted" if xml.match?(/<!ENTITY/i)
      # Parsing is bounded by the XML byte cap, but is not supervised per chunk.
      # A final checkpoint refuses the next operation if parsing exhausts time.
      keys = REXML::Document.new(xml).get_elements("//key")
      keys.select { |key| key.text == "TestBundlePath" }.each do |key|
        value = key.next_element
        unless value&.name == "string" && value.text.is_a?(String) && !value.text.empty? && !value.text.include?("\0")
          raise Stop, "Invalid TestBundlePath"
        end
        path = value.text
        if path.start_with?("__TESTROOT__/")
          path = File.expand_path(path.delete_prefix("__TESTROOT__/"), File.dirname(xml_path))
        end
        unless path.start_with?("/") && !path.match?(/__[^\/]*__/)
          raise Stop, "Unsupported TestBundlePath reference"
        end
        begin
          resolved = File.realpath(path)
          unless resolved.start_with?(self["source_root"] + "/") && File.directory?(resolved)
            raise Stop, "TestBundlePath must be a directory inside source root"
          end
        rescue SystemCallError
          raise Stop, "Invalid TestBundlePath directory"
        end
      end
      hosts = keys.filter_map do |key|
        next unless key.text == "TestHostPath"
        value = key.next_element
        raise Stop, "Invalid TestHostPath" unless value&.name == "string" && value.text.is_a?(String)
        value.text.gsub("__TESTROOT__", File.dirname(xml_path))
      end
      expected = self["files"].fetch("test_host").fetch("path")
      raise Stop, "xctestrun TestHost identity mismatch" unless !hosts.empty? && hosts.all? { |host| host == expected }
      self.class.checkpoint!(deadline, progress)
      true
    rescue REXML::ParseException => error
      raise Stop, "Invalid xctestrun: #{error.class}"
    end
  end
end
