#!/usr/bin/env bash
set -euo pipefail

failures=0
warn() {
  echo "BLOCKED $1"
  failures=$((failures + 1))
}
pass() { echo "PASS $1"; }

if grep -q 'audio-conversion-not-implemented' web/src/services/EmbeddedConverter.ts; then
  warn "Web embedded Rust adapter still has no audio conversion capability"
else
  pass "Web embedded Rust adapter exposes audio conversion"
fi

if grep -q 'ConversionService' web/src/hooks/useConversionFlow.ts; then
  warn "Web conversion flow still imports the HTTP ConversionService"
else
  pass "Web conversion flow does not import HTTP ConversionService"
fi

if grep -RqsE 'ApiClient|PythonBridge|EventSource|http://' flutter_app/lib; then
  warn "Flutter product code still contains legacy HTTP/Python transport references"
else
  pass "Flutter product code contains no legacy HTTP/Python transport references"
fi

if grep -q 'python_app/convert' web/src/hooks/useConversionFlow.ts; then
  warn "Web conversion flow still advertises the legacy Python CLI"
else
  pass "Web conversion flow does not advertise the legacy Python CLI"
fi

if (( failures > 0 )); then
  echo "RESULT BLOCKED ($failures)"
  exit 1
fi

echo "RESULT PASS"
