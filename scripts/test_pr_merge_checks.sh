#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
assert_gate() {
  local expected="$1" payload="$2" actual
  actual=$(jq -f pr_merge_checks_pass.jq <<< "$payload")
  [[ "$actual" == "$expected" ]] || { echo "Expected $expected, got $actual" >&2; exit 1; }
}
assert_gate false '{"ci":null,"checks":[]}'
assert_gate false '{"ci":{"status":"in_progress","conclusion":null},"checks":[{"__typename":"StatusContext","state":"SUCCESS"}]}'
assert_gate false '{"ci":{"status":"completed","conclusion":"failure"},"checks":[{"__typename":"StatusContext","state":"SUCCESS"}]}'
assert_gate false '{"ci":{"status":"completed","conclusion":"success"},"checks":[]}'
for status in IN_PROGRESS QUEUED; do
  assert_gate false "{\"ci\":{\"status\":\"completed\",\"conclusion\":\"success\"},\"checks\":[{\"__typename\":\"CheckRun\",\"status\":\"$status\",\"conclusion\":null}]}"
done
for conclusion in FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED; do
  assert_gate false "{\"ci\":{\"status\":\"completed\",\"conclusion\":\"success\"},\"checks\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}]}"
done
assert_gate true '{"ci":{"status":"completed","conclusion":"success"},"checks":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"StatusContext","state":"SUCCESS"},{"name":"Enable auto-merge after required checks","__typename":"CheckRun","status":"IN_PROGRESS"}]}'
assert_gate false '{"ci":{"status":"completed","conclusion":"success"},"checks":[{"__typename":"StatusContext","state":"FAILURE"}]}'
echo 'Automatic merge gate: 12 cases passed.'
