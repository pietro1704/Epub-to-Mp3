#!/usr/bin/env ruby
# Read-only validation; acquiring a native build lease must never start a download.
require_relative 'fetch_onnxruntime_macos'
begin
  puts PrebuiltOnnxRuntime.validate
rescue StandardError => error
  abort "#{error.message}. Run mise run onnxruntime:host to install the verified prebuilt runtime; no source compilation is required."
end
