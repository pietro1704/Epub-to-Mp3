# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# Run real entry-point scripts with a fake booted device and compiler markers.
# No native compiler, Simulator service or app is executed.
class NativeEntrypointSafetyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_booted_simulator_blocks_before_every_bootstrap_compiler
    skip "Intel macOS policy" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    %w[verify_tts_preferences.rb verify_portable_tts.rb device-workflow.sh].each do |entry|
      Dir.mktmpdir("native-entry-safety-") do |directory|
        scripts = File.join(directory, "scripts")
        FileUtils.mkdir_p(scripts)
        %W[#{entry} native_job.rb native_build_preflight.rb mac_build_budget.rb].each do |name|
          content = File.read(File.join(ROOT, "scripts", name)).gsub("/tmp/epub2mp3.heavy-job.lock", File.join(directory, "lease"))
          File.write(File.join(scripts, name), content)
        end
        marker = File.join(directory, "compiler")
        runtime = File.join(directory, "runtime")
        FileUtils.mkdir_p(runtime)
        File.write(File.join(scripts, "prepare_onnxruntime_macos.rb"), "puts #{runtime.inspect}\n")
        { "xcrun" => <<~'SH', "pgrep" => "#!/bin/bash\nexit 1\n", "mise" => <<~'MISE' }.each do |name, body|
          #!/bin/bash
          if [[ "$1" == simctl ]]; then
            echo '{"devices":{"fixture":[{"state":"Booted"}]}}'
            exit 0
          fi
          touch "$COMPILER_MARKER"
          exit 23
        SH
          #!/bin/bash
          [[ "$1" == exec && "$2" == -- ]] || exit 98
          shift 2
          if [[ "$1" == ruby ]]; then shift; exec "$FIXTURE_RUBY" "$@"; fi
          touch "$COMPILER_MARKER"
          exit 23
        MISE
          path = File.join(directory, name)
          File.write(path, body)
          File.chmod(0o755, path)
        end
        environment = { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "COMPILER_MARKER" => marker,
                        "FIXTURE_RUBY" => RbConfig.ruby, "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil }
        command = entry.end_with?(".rb") ? [RbConfig.ruby, File.join(scripts, entry)] : ["bash", File.join(scripts, entry), "host-tests"]
        output, error, status = Open3.capture3(environment, *command, chdir: directory)
        assert_equal 75, status.exitstatus, "#{entry}: #{output}#{error}"
        refute File.exist?(marker), "#{entry} started a compiler before preflight"
      end
    end
  end
end
