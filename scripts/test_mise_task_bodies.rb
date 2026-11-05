# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "mise_task_bodies"

class MiseTaskBodiesTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir("mise-task-bodies-"))
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p(@bin)
    @trace = File.join(@root, "trace")
    shim = File.join(@bin, "mise")
    File.write(shim, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("TASK_TRACE"), "a") { |f| f.puts JSON.generate([Dir.pwd, ARGV]) }
      if ENV["TASK_FAIL"] == "1"
        warn "discovery refused"
        exit 17
      end
      puts JSON.generate([{name: "first", run: ["echo 'literal $HOME'", "exit 23"]},
                          {name: "hidden", run: ["echo hidden"]}])
    RUBY
    File.chmod(0o755, shim)
    @env = {"PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "TASK_TRACE" => @trace}
    @helper = File.expand_path("mise_task_bodies", __dir__)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def invoke(names, env = {})
    Open3.capture3(@env.merge(env), RbConfig.ruby, "-r", @helper, "-e",
                  "puts JSON.generate(MiseTaskBodies.load(ARGV.shift, ARGV))", @root, *names)
  end

  def test_multiple_tasks_use_one_discovery_and_preserve_exact_shell_bodies
    output, error, status = invoke(%w[first hidden])
    assert status.success?, error
    assert_equal({"first" => "echo 'literal $HOME'\nexit 23", "hidden" => "echo hidden"}, JSON.parse(output))
    assert_equal [[@root, %w[tasks ls --json --hidden]]], File.readlines(@trace).map { |line| JSON.parse(line) }
  end

  def test_discovery_failure_cannot_return_partial_bodies
    output, error, status = invoke(%w[first], "TASK_FAIL" => "1")
    refute status.success?
    assert_empty output
    assert_includes error, "discovery refused"
  end

  def test_missing_requested_task_fails_before_any_bodies_are_returned
    output, error, status = invoke(%w[first missing])
    refute status.success?
    assert_empty output
    assert_includes error, "missing"
  end
end
