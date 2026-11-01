# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

class XcodeScriptEnvironmentTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_generated_script_phases_hide_environment_without_changing_commands
    skip 'Xcode project generation requires macOS' unless RUBY_PLATFORM.include?('darwin')
    _output, _error, available = Open3.capture3('which', 'xcodegen')
    skip 'XcodeGen must already be installed; this test never installs tools' unless available.success?

    Dir.mktmpdir('xcode script environment ') do |fixture|
      paths, status = Open3.capture2('git', '-C', ROOT, 'ls-files', '-z',
                                    '--cached', '--others', '--exclude-standard', '--', 'ios/EpubToMp3')
      assert status.success?
      paths.split("\0").uniq.each do |relative|
        source = File.join(ROOT, relative)
        next unless File.file?(source)
        destination = File.join(fixture, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      end
      binary = File.join(fixture, 'target/release/libconverter_ffi.dylib')
      FileUtils.mkdir_p(File.dirname(binary))
      File.write(binary, 'Descriptor-only fixture; never compiled or loaded.')
      project = File.join(fixture, 'ios/EpubToMp3')
      spec = File.join(project, 'project.yml')
      candidate = File.read(spec)
      generated = generate(project)
      phases = generated.fetch('objects').select { |_id, object| object['isa'] == 'PBXShellScriptBuildPhase' }
      assert_equal 4, phases.size
      phases.each_value { |phase| assert_equal '0', phase['showEnvVarsInLog'].to_s }

      File.write(spec, candidate.gsub(/^\s+showEnvVars: false\n/, ''))
      original = generate(project)
      phases.each_key do |id|
        generated.fetch('objects').fetch(id).delete('showEnvVarsInLog')
        original.fetch('objects').fetch(id).delete('showEnvVarsInLog')
      end
      assert_equal original, generated, 'Only environment logging may change in the generated project'
    end
  end

  private

  def generate(project)
    output, error, status = Open3.capture3('xcodegen', 'generate', chdir: project)
    raise "XcodeGen failed: #{output}\n#{error}" unless status.success?
    output, error, status = Open3.capture3('plutil', '-convert', 'json', '-o', '-',
                                         File.join(project, 'EpubToMp3.xcodeproj/project.pbxproj'))
    raise "Cannot read generated project: #{error}" unless status.success?
    JSON.parse(output)
  end
end
