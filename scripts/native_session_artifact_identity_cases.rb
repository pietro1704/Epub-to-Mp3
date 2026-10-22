# frozen_string_literal: true

# Loaded by test_native_simulator_session.rb; preserve the existing suite selectors and fixture.
class NativeSimulatorSessionTest
  def test_source_over_one_mib_is_rejected_even_with_a_valid_digest
    load_subject
    source = @plan.fetch("files").fetch("source")
    File.open(source.fetch("path"), "wb") { |file| file.truncate(1_048_577) }
    source["sha256"] = Digest::SHA256.file(source.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))

    error = assert_raises(NativeSimulatorSession::Stop) do
      NativeSimulatorSession::Plan.new(@plan_path)
    end
    assert_match(/size limit/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_each_role_rejects_oversized_regular_files_before_opening_them
    load_subject
    NativeSimulatorSession::Plan::FILE_LIMITS.each do |role, limit|
      path = File.join(@directory, "oversized-#{role}")
      File.open(path, "wb") { |file| file.truncate(limit + 1) }
      with_method(File, :open, ->(*) { flunk "Oversized #{role} was opened" }) do
        error = assert_raises(NativeSimulatorSession::Stop) do
          NativeSimulatorSession::Plan.read_identity(path, limit: limit, deadline: NativeSimulatorSession.now + 2)
        end
        assert_match(/size limit/, error.message)
      end
    end
    assert_empty operations
  end

  def test_exact_role_boundaries_are_hashed_and_capture_the_same_bytes
    load_subject
    NativeSimulatorSession::Plan::FILE_LIMITS.each do |role, limit|
      path = File.join(@directory, "boundary-#{role}")
      File.open(path, "wb") { |file| file.truncate(limit) }
      identity, contents = NativeSimulatorSession::Plan.read_identity(path, limit: limit,
        deadline: NativeSimulatorSession.now + 5, capture: true)
      assert_equal limit, contents.bytesize
      assert_equal Digest::SHA256.hexdigest(contents), identity.last
    end
  end

  def test_plan_and_manifest_are_not_reopened_for_unbounded_parsing
    load_subject
    with_method(File, :read, ->(*) { flunk "Plan or manifest was reopened for parsing" }) do
      assert NativeSimulatorSession::Plan.new(@plan_path).verify!
    end
  end

  def test_identity_rejects_symlinks_directories_and_fifos_without_opening_them
    load_subject
    link = File.join(@directory, "identity-link")
    fifo = File.join(@directory, "identity-fifo")
    File.symlink(@tool, link)
    File.mkfifo(fifo)
    with_method(File, :open, ->(*) { flunk "Nonregular identity was opened" }) do
      [link, @directory, fifo].each do |path|
        assert_raises(NativeSimulatorSession::Stop) do
          NativeSimulatorSession::Plan.read_identity(path, limit: 65_536, deadline: NativeSimulatorSession.now + 2)
        end
      end
    end
  end

  def test_replacement_between_lstat_and_open_is_rejected_before_read_and_closes_fd
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    replacement = path + ".replacement"
    File.write(replacement, File.read(path))
    original_open = File.method(:open)
    opened = nil
    intercept = lambda do |name, *arguments, &block|
      File.rename(replacement, path)
      original_open.call(name, *arguments) do |file|
        opened = file
        file.define_singleton_method(:read) { |*| raise "Replaced descriptor was read" }
        block.call(file)
      end
    end
    with_method(File, :open, intercept) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2, deadline: NativeSimulatorSession.now + 2)
      end
      assert_match(/before reading/, error.message)
    end
    assert opened.closed?
  end

  def test_fifo_replacement_between_lstat_and_open_is_bounded_and_closes_fd
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    ack_reader, ack_writer = IO.pipe
    resume_reader, resume_writer = IO.pipe
    result_path = File.join(@directory, "fifo-result.json")
    child = fork do
      ack_reader.close
      resume_writer.close
      original_open = File.method(:open)
      opened = nil
      result = {}
      intercept = lambda do |name, *arguments, &block|
        ack_writer.write("before-open\n")
        ack_writer.flush
        raise "Missing FIFO replacement acknowledgement" unless resume_reader.read(1) == "1"
        original_open.call(name, *arguments) do |file|
          opened = file
          file.define_singleton_method(:read) { |*| raise "FIFO descriptor was read" }
          block.call(file)
        end
      end
      begin
        with_method(File, :open, intercept) do
          NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2,
            deadline: NativeSimulatorSession.now + 2)
          result["reason"] = "Unexpected FIFO acceptance"
        end
      rescue NativeSimulatorSession::Stop => error
        result["reason"] = error.message
        result["closed"] = opened&.closed?
      rescue StandardError => error
        result["fixture_error"] = "#{error.class}: #{error.message}"
      ensure
        File.write(result_path, JSON.generate(result))
      end
      exit! 0
    end
    ack_writer.close
    resume_reader.close
    assert_equal "before-open\n", Timeout.timeout(12) { ack_reader.gets }
    File.unlink(path)
    File.mkfifo(path)
    resume_writer.write("1")
    resume_writer.close
    _, status = Timeout.timeout(3) { Process.waitpid2(child) }
    child = nil
    assert status.success?
    result = JSON.parse(File.read(result_path))
    refute result.key?("fixture_error"), result.inspect
    assert_match(/changed before reading/, result.fetch("reason"))
    assert_equal true, result["closed"]
    assert_empty operations
  ensure
    if child
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.waitpid(child) rescue Errno::ECHILD
    end
    [ack_reader, ack_writer, resume_reader, resume_writer].compact.each { |io| io.close unless io.closed? }
  end

  def test_in_place_change_during_read_is_rejected_and_closes_fd
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    File.write(path, "a" * (2 * NativeSimulatorSession::Plan::CHUNK_BYTES))
    original_open = File.method(:open)
    opened = nil
    intercept = lambda do |name, *arguments, &block|
      original_open.call(name, *arguments) do |file|
        opened = file
        original_read = file.method(:read)
        changed = false
        file.define_singleton_method(:read) do |length|
          chunk = original_read.call(length)
          unless changed
            changed = true
            original_open.call(path, "r+b") { |writer| writer.write("b") }
          end
          chunk
        end
        block.call(file)
      end
    end
    with_method(File, :open, intercept) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2, deadline: NativeSimulatorSession.now + 2)
      end
      assert_match(/changed while hashing/, error.message)
    end
    assert opened.closed?
  end

  def test_validation_deadline_refuses_before_opening_any_artifact
    load_subject
    with_method(File, :open, ->(*) { flunk "Expired validation opened an artifact" }) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(@plan_path, limit: 65_536, deadline: NativeSimulatorSession.now - 1)
      end
      assert_match(/deadline/, error.message)
    end
  end

  def test_plan_rejects_explicit_test_bundle_outside_authorized_root_before_workers
    load_subject
    assert_instance_of NativeSimulatorSession::Plan, NativeSimulatorSession::Plan.new(@plan_path)
    external = Dir.mktmpdir("simulator-external-bundle-")
    bundle = File.join(File.realpath(external), "ExternalTests.xctest")
    FileUtils.mkdir_p(bundle)
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key><string>#{bundle}</string></dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))

    error = assert_raises(NativeSimulatorSession::Stop) do
      NativeSimulatorSession::Plan.new(@plan_path)
    end
    assert_match(/TestBundlePath/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_accepts_testroot_bundle_and_rejects_symlink_escape_on_revalidation
    load_subject
    bundle = File.join(@directory, "OwnedTests.xctest")
    FileUtils.mkdir_p(bundle)
    external = Dir.mktmpdir("simulator-external-bundle-")
    external_bundle = File.join(File.realpath(external), "ExternalTests.xctest")
    FileUtils.mkdir_p(external_bundle)
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key><string>__TESTROOT__/OwnedTests.xctest</string></dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))
    plan = NativeSimulatorSession::Plan.new(@plan_path)
    assert_instance_of NativeSimulatorSession::Plan, plan

    Dir.rmdir(bundle)
    File.symlink(external_bundle, bundle)
    error = assert_raises(NativeSimulatorSession::Stop) { plan.verify! }
    assert_match(/TestBundlePath/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_rejects_testroot_traversal_to_existing_external_bundle
    load_subject
    external = Dir.mktmpdir("simulator-external-bundle-", File.dirname(@directory))
    FileUtils.mkdir_p(File.join(external, "ExternalTests.xctest"))
    reference = "__TESTROOT__/../#{File.basename(external)}/ExternalTests.xctest"
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string>#{reference}</string>")
    end
    assert_equal "TestBundlePath must be a directory inside source root", error.message
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_rejects_unsupported_test_bundle_placeholder
    load_subject
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string>__TESTHOST__/X.xctest</string>")
    end
    assert_equal "Unsupported TestBundlePath reference", error.message
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_plan_rejects_empty_test_bundle_value
    load_subject
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string/>")
    end
    assert_equal "Invalid TestBundlePath", error.message
    assert_empty operations
    refute File.exist?(@lease)
  end
end
