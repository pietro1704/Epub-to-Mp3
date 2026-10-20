# frozen_string_literal: true
require 'fileutils'
require 'digest'
root = File.expand_path('../../..', __dir__)
downloads = File.join(root, '.reports/tts-six/20261014/downloads')
FileUtils.mkdir_p(downloads)
def fetch(url, file, checksum = nil)
  abort "Download failed #{url}" unless system('curl', '-fLsS', '--retry', '2', '--max-time', '240', url, '-o', file)
  abort "Checksum mismatch #{file}" if checksum && Digest::SHA256.file(file).hexdigest != checksum
end
frameworks = File.join(downloads, 'frameworks')
FileUtils.mkdir_p(frameworks)
fetch('https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-shared.xcframework.zip', File.join(downloads, 'sherpa-ios.zip'), '449fd0d139ef1efc11f8a202cd47bd6cff448ada1ba289210946bc3f2d65a689')
fetch('https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-shared-xcframework-1.28.2.xcframework.zip', File.join(downloads, 'ort-ios.zip'), 'd955b44322de53cc0be60e4939c89e46c2ba9dc0e9eef7f25ec8c73427ac6546')
%w[sherpa-ios ort-ios].each { |name| abort unless system('unzip', '-oq', File.join(downloads, name + '.zip'), '-d', frameworks) }
fetch('https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/swift-api-examples/SherpaOnnx.swift', File.join(downloads, 'SherpaOnnx.swift'))
%w[vits-piper-pt_BR-edresson-low vits-piper-pt_BR-faber-medium kokoro-int8-multi-lang-v1_0 sherpa-onnx-supertonic-3-tts-int8-2026-05-11].each do |name|
  archive = File.join(downloads, name + '.tar.bz2')
  fetch("https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/#{name}.tar.bz2", archive)
  abort unless system('tar', '-xjf', archive, '-C', downloads)
end
pocket = File.join(downloads, 'pocket-portuguese')
FileUtils.mkdir_p(pocket)
revision = '58a6d00cf13d239b6748cb0769f35c580a8f606c'
%w[bos_before_voice.npy bundle.json flow_lm_flow_int8.onnx flow_lm_main_int8.onnx mimi_decoder_int8.onnx mimi_encoder.onnx text_conditioner.onnx tokenizer.model].each do |name|
  fetch("https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/#{revision}/onnx/portuguese/#{name}", File.join(pocket, name))
end
fetch('https://raw.githubusercontent.com/netai369/PocketTTS.cpp-multilingual/3ed176a2b238b7ddb62b4aea4e7469ae4bcc3489/pocket_tts.cpp', File.join(downloads, 'pocket_tts.cpp'))
fetch('https://github.com/google/sentencepiece/archive/refs/tags/v0.2.1.tar.gz', File.join(downloads, 'sentencepiece.tar.gz'))
abort unless system('tar', '-xzf', File.join(downloads, 'sentencepiece.tar.gz'), '-C', downloads)
%w[dr_wav.h dr_mp3.h dr_flac.h].each { |name| fetch("https://raw.githubusercontent.com/mackron/dr_libs/dfe8377631000664666519fdb83da193fd8037f4/#{name}", File.join(downloads, name)) }
reference = File.join(root, '.reports/tts-host/20261013T200903Z/short-1-edge.mp3')
abort 'Existing synthetic Edge reference fixture is required' unless File.file?(reference)
abort unless system('ffmpeg', '-v', 'error', '-y', '-i', reference, '-ar', '24000', '-ac', '1', File.join(pocket, 'reference.wav'))
