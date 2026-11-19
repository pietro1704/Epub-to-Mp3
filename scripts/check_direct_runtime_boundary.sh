#!/usr/bin/env bash
set -euo pipefail

# Exercise runtime behavior; compatibility identifiers are not transport evidence.
selection="${1:-flutter}"
if [[ $# -gt 1 ]] || [[ "$selection" != flutter ]]; then
  echo 'Usage: check_direct_runtime_boundary.sh [flutter]' >&2
  exit 64
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
command -v mise >/dev/null || { echo 'BLOCKED: mise is required' >&2; exit 127; }

if [[ "$selection" == flutter ]]; then
  (
    cd flutter_app
    mise exec -- flutter test --no-pub \
      test/local_conversion_job_test.dart \
      test/jobs_list_screen_test.dart \
      test/convert_screen_test.dart \
      test/rust_playback_conversion_test.dart \
      test/desktop_conversion_worker_test.dart
  )
fi
echo "RESULT PASS: $selection executable embedded-runtime contracts; native/device evidence remains separate"
