#!/usr/bin/env ruby
# frozen_string_literal: true
require 'digest'
require 'open3'

# Keep producer and Faber caches on the same compiler/SDK/flags contract.
module IntelRustCacheIdentity
  module_function
  def calculate(environment = ENV, direct: false, runner: Open3.method(:capture3))
    prefix = direct ? [] : %w[mise exec --]
    command = lambda do |*argv|
      output, _, status = runner.call(*argv)
      raise "Cannot inspect cache toolchain: #{argv.first}" unless status.success?
      output
    end
    body = "image=#{environment.fetch('ImageOS', 'unknown')}/#{environment.fetch('ImageVersion', 'unknown')}\n"
    body += command.call(*prefix, 'rustc', '-vV')
    body += command.call(*prefix, 'cargo', '--version')
    body += command.call('xcodebuild', '-version')
    body += "sdk_path=#{command.call('xcrun', '--sdk', 'macosx', '--show-sdk-path').strip}\n"
    body += "sdk_version=#{command.call('xcrun', '--sdk', 'macosx', '--show-sdk-version').strip}\n"
    clang = command.call('xcrun', '--find', 'clang').strip
    body += "clang_sha256=#{Digest::SHA256.file(clang).hexdigest}\n"
    body += "MACOSX_DEPLOYMENT_TARGET=12.0\nORT_PREFER_DYNAMIC_LINK=1\nCARGO_BUILD_JOBS=1\nCMAKE_BUILD_PARALLEL_LEVEL=1\n"
    %w[RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER].each { |name| body += "#{name}=#{environment.fetch(name, '')}\n" }
    Digest::SHA256.hexdigest(body)
  end
end

if $PROGRAM_NAME == __FILE__
  direct = ARGV.delete('--direct')
  abort 'Usage: intel_rust_cache_identity.rb [--direct]' unless ARGV.empty?
  output = ENV.fetch('GITHUB_OUTPUT')
  File.open(output, 'a') { |file| file.puts "identity=#{IntelRustCacheIdentity.calculate(direct: !!direct)}" }
end
