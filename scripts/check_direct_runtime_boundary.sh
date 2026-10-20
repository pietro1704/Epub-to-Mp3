#!/usr/bin/env bash
set -euo pipefail

# Compatibility identifiers are not evidence of an active runtime dependency.
# Exercise client selection, missing-capability failures, persisted jobs and the
# rendered application instead. These contracts do not replace device evidence.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec mise exec -- ruby - <<'RUBY'
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
web = ['mise', 'exec', '--', 'npm', '--prefix', 'web', 'run', 'test', '--',
       'src/services/EmbeddedConverter.test.ts',
       'src/services/BrowserConversionClient.test.ts',
       'src/test/App.integration.test.tsx', 'src/test/useConversionFlow.test.ts']
exit(1) unless system(*web)
Dir.chdir('flutter_app') do
  flutter = ['mise', 'exec', '--', 'flutter', 'test', '--no-pub',
             'test/local_conversion_job_test.dart', 'test/jobs_list_screen_test.dart',
             'test/convert_screen_test.dart', 'test/rust_playback_conversion_test.dart']
  exit(1) unless system(*flutter)
end
puts 'RESULT PASS: executable embedded-runtime contracts; native/device evidence remains separate'
RUBY
