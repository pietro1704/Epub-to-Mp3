#!/usr/bin/env bash
# Print a Markdown evidence report for one GitHub Actions run: per-job result and
# duration, executed test counts parsed from job logs, and artifact links.
# Usage: ci_branch_evidence_report.sh <run_id>   (needs gh; GH_REPO or a git remote)
set -uo pipefail

run_id="${1:?usage: ci_branch_evidence_report.sh <run_id>}"
repo="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

summary="$(gh api "repos/$repo/actions/runs/$run_id" --jq '"- Run: \(.html_url)\n- Branch: `\(.head_branch)`  Head: `\(.head_sha)`\n- Event: \(.event)  Status: \(.status)  Conclusion: \(.conclusion // "pending")"')"
# Newer gh refuses logs with terminal escapes unless told otherwise; older gh lacks the flag.
fetch_log() {
  gh api --allow-escape-sequences "repos/$repo/actions/jobs/$1/logs" 2>/dev/null || gh api "repos/$repo/actions/jobs/$1/logs" 2>/dev/null
}

printf '## Branch evidence\n\n%s\n\n' "$summary"

printf '### Jobs\n\n| Job | Result | Duration | Tests |\n|---|---|---|---|\n'
gh api --paginate "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
  --jq '.jobs[] | [.id, .name, (.conclusion // .status), (if .started_at and .completed_at then ((.completed_at|fromdateiso8601) - (.started_at|fromdateiso8601)) else 0 end)] | @tsv' |
while IFS=$'\t' read -r job_id name result seconds; do
  tests="-"
  if [ "$result" = success ] || [ "$result" = failure ]; then
    log="$(fetch_log "$job_id" | sed $'s/\x1b\\[[0-9;]*m//g' || true)"
    parts=()
    # XCTest: the last "Executed N tests, with F failures" line is the overall total.
    xc="$(printf '%s\n' "$log" | grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' | tail -1 | sed -E 's/.*(Executed [0-9]+ tests?, with [0-9]+ failures?).*/\1/')"
    [ -n "$xc" ] && parts+=("XCTest: ${xc#Executed }")
    cargo="$(printf '%s\n' "$log" | awk '/test result:/ { for (i = 1; i <= NF; i++) { if ($i == "passed;") p += $(i-1); if ($i == "failed;") f += $(i-1); if ($i == "ignored;") g += $(i-1) } n++ } END { if (n) printf "cargo: %d passed, %d failed, %d ignored", p, f, g }')"
    [ -n "$cargo" ] && parts+=("$cargo")
    fp="$(printf '%s\n' "$log" | grep -c '✅ ')"; ff="$(printf '%s\n' "$log" | grep -c '❌ ')"
    [ "$fp" -gt 0 ] || [ "$ff" -gt 0 ] && parts+=("flutter: $fp passed, $ff failed")
    mt="$(printf '%s\n' "$log" | awk '/[0-9]+ runs, [0-9]+ assertions/ { r += $1; for (i = 1; i <= NF; i++) { if ($i == "failures," ) f += $(i-1); if ($i == "errors,") e += $(i-1); if ($i == "skips") s += $(i-1) } n++ } END { if (n) printf "minitest: %d runs, %d failures, %d errors, %d skips", r, f, e, s }')"
    [ -n "$mt" ] && parts+=("$mt")
    jvm="$(printf '%s\n' "$log" | grep -E 'ANDROID_JVM_TESTS' | tail -1 | sed -E 's/.*ANDROID_JVM_TESTS/android-jvm:/')"
    [ -n "$jvm" ] && parts+=("$jvm")
    [ ${#parts[@]} -gt 0 ] && tests="$(IFS=';'; echo "${parts[*]}")"
  fi
  printf '| %s | %s | %dm%02ds | %s |\n' "$name" "$result" $((seconds / 60)) $((seconds % 60)) "$tests"
done

printf '\n### Artifacts (xcresult, screenshots, diagnostics)\n\n'
artifacts="$(gh api --paginate "repos/$repo/actions/runs/$run_id/artifacts?per_page=100" --jq ".artifacts[] | \"- [\(.name)](https://github.com/$repo/actions/runs/$run_id/artifacts/\(.id)) (\(.size_in_bytes / 1048576 | floor) MiB, expires \(.expires_at[:10]))\"")"
if [ -n "$artifacts" ]; then printf '%s\n' "$artifacts"; else printf 'None uploaded.\n'; fi
