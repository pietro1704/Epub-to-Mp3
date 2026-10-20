# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'time'

root = File.expand_path('../../..', __dir__)
assets = File.join(root, '.reports/tts-mac-20261016/assets')
FileUtils.mkdir_p(assets)
manifest = []
items = {
  'sherpa-onnx-v1.13.8-osx-x64-shared.tar.bz2' => 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-x64-shared.tar.bz2',
  'llama-b11669-bin-macos-x64.tar.gz' => 'https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-bin-macos-x64.tar.gz'
}
%w[vits-piper-pt_BR-edresson-low vits-piper-pt_BR-faber-medium kokoro-int8-multi-lang-v1_0 sherpa-onnx-supertonic-3-tts-int8-2026-05-11].each do |name|
  items[name + '.tar.bz2'] = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/#{name}.tar.bz2"
end
items.each do |name, url|
  path = File.join(assets, name)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "Preparing #{name}"
  STDOUT.flush
  ok = File.file?(path) || system('curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--max-time', '300', url, '-o', path + '.partial')
  File.rename(path + '.partial', path) if ok && File.file?(path + '.partial')
  row = { name: name, url: url, success: !!ok, preparation_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
  if ok
    row[:bytes] = File.size(path)
    row[:sha256] = Digest::SHA256.file(path).hexdigest
    row[:extracted] = system('tar', '-xf', path, '-C', assets)
  end
  manifest << row
  File.write(File.join(assets, 'download-manifest.json'), JSON.pretty_generate(manifest) + "\n")
end
library = File.join(assets, 'sherpa-onnx-v1.13.8-osx-x64-shared/lib/libonnxruntime.dylib')
extension_directory = File.join(root, '.reports/tts-mac-20261016/packages/sherpa_onnx/lib')
FileUtils.ln_sf(library, File.join(extension_directory, 'libonnxruntime.dylib')) if File.directory?(extension_directory)
