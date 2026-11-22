#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

# Signing certificate of the official Android release key created on 2026-11-22 (replaces the v0.10.5 key, whose keystore could not be recovered).
OFFICIAL_CERTIFICATE_SHA256 = '35cb05834223999543d0b2695e42437681e7fb2d7df64b74de42ca8201f50e56'

def verify_release_signature(apk, platform, sdk_options)
  stdout, stderr, status = Open3.capture3('apksigner', 'verify', '--verbose', '--print-certs', *sdk_options, apk)
  unless status.success?
    details = [stderr.strip, stdout.strip].reject(&:empty?).join("\n")
    abort ["APK signature verification failed for #{platform} (#{status}).", details].reject(&:empty?).join("\n")
  end

  signer_counts = stdout.scan(/^Number of signers: ([^\r\n]*)/)
  signer_digests = stdout.scan(/^Signer #(\d+) certificate SHA-256 digest: ([^\r\n]*)/)
  signer_number, digest = signer_digests.first

  unless signer_counts == [['1']] && signer_digests.length == 1 && signer_number == '1' &&
         digest.match?(/\A[0-9a-fA-F]{64}\z/)
    abort "Expected exactly one signer and its full SHA-256 certificate digest for #{platform}.\n#{stdout}"
  end

  return if digest.downcase == OFFICIAL_CERTIFICATE_SHA256

  abort "Unexpected APK signing certificate for #{platform}. " \
        "Expected #{OFFICIAL_CERTIFICATE_SHA256}, found #{digest.downcase}."
rescue Errno::ENOENT
  abort 'apksigner executable not found on PATH. Add Android SDK Build Tools to PATH.'
rescue SystemCallError => error
  abort "Could not run apksigner for #{platform}. #{error.message}"
end

abort "Usage: ruby #{File.basename(__FILE__)} APK" unless ARGV.length == 1

apk = File.expand_path(ARGV.first)
abort "APK file not found: #{apk}" unless File.file?(apk)

verify_release_signature(apk, 'supported Android API levels', [])
verify_release_signature(apk, 'Android API 28', %w[--min-sdk-version 28 --max-sdk-version 28])
puts "Verified official Android release signing certificate #{OFFICIAL_CERTIFICATE_SHA256}."
