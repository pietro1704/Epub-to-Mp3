# frozen_string_literal: true
require 'fileutils'
require 'digest'
require 'json'
root = File.expand_path('../../..', __dir__)
destination = File.join(root, '.reports/tts-mac-20261016/assets/pocket/portuguese')
FileUtils.mkdir_p(destination)
revision = '58a6d00cf13d239b6748cb0769f35c580a8f606c'
files = %w[bundle.json tokenizer.model bos_before_voice.npy mimi_encoder.onnx text_conditioner.onnx flow_lm_main_int8.onnx flow_lm_flow_int8.onnx mimi_decoder_int8.onnx]
manifest = []
files.each do |name|
  url = "https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/#{revision}/onnx/portuguese/#{name}"
  path = File.join(destination, name)
  abort "Download failed: #{name}" unless File.file?(path) || system('curl', '-fLsS', '--max-time', '300', '--retry', '2', url, '-o', path)
  manifest << { url: url, bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest }
  puts "Prepared #{name}"
  STDOUT.flush
end
File.write(File.join(destination, 'benchmark-provenance.json'), JSON.pretty_generate(manifest) + "\n")
