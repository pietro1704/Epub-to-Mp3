# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class OnnxruntimeSimulatorJobsTest < Minitest::Test
  def test_source_recipe_passes_exactly_one_parallel_job
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "scripts"))
      FileUtils.cp(File.join(__dir__, "build_onnxruntime_ios_simulator.sh"), File.join(root, "scripts"))
      source = File.join(root, "target/onnxruntime-ios15-src")
      FileUtils.mkdir_p(File.join(source, ".git"))
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "mise"), <<~'SH')
        #!/bin/bash
        shift 2
        exec "$@"
      SH
      File.chmod(0o755, File.join(bin, "mise"))
      File.write(File.join(source, "build.sh"), <<~'SH')
        #!/bin/bash
        printf '%s\n' "$@" > "$RECIPE_ARGS"
        exit 47
      SH
      _, _, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "RECIPE_ARGS" => File.join(root, "args") },
        "bash", File.join(root, "scripts/build_onnxruntime_ios_simulator.sh"))
      assert_equal 47, status.exitstatus
      args = File.readlines(File.join(root, "args"), chomp: true)
      assert_equal "1", args[args.index("--parallel") + 1], "ONNX defaults an unqualified --parallel to all CPUs"
    end
  end
end
