#!/usr/bin/env bash
# Dispatch the PR-gate jobs for a PUSHED branch, wait, print per-job results.
#
# Usage: scripts/ci_branch_evidence.sh <branch> [scope] [filter]
#   scope   auto (default: classify the diff against master like the PR gate),
#           apple | rust | flutter | android | rails | all, or windows
#           (dispatches the Windows package workflow, not part of the PR gate)
#   filter  comma-separated EpubToMp3Tests classes for the iOS Simulator job
# Env: CI_EVIDENCE_TIMEOUT_MIN (default 90), CI_EVIDENCE_REPO (default: current gh repo)
# Exit: 0 green, 1 run failed or cancelled, 2 usage/precondition, 3 dispatch or timeout problem.
# Needs only bash and an authenticated gh. The branch must contain this workflow
# version (based on a master that has the `scope` input of ci.yml).
set -uo pipefail

branch="${1:-}"; scope="${2:-auto}"; filter="${3:-}"
[ -n "$branch" ] || { sed -n '2,12p' "$0" >&2; exit 2; }
case "$scope" in auto|apple|rust|flutter|android|rails|all|windows) ;; *) echo "Unknown scope: $scope" >&2; exit 2 ;; esac
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${CI_EVIDENCE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}" || exit 2
timeout_min="${CI_EVIDENCE_TIMEOUT_MIN:-90}"

remote_sha="$(gh api "repos/$repo/branches/$branch" --jq .commit.sha 2>/dev/null)" || { echo "Branch '$branch' is not pushed to $repo" >&2; exit 2; }
if local_sha="$(git rev-parse --verify -q "refs/heads/$branch" 2>/dev/null)" && [ "$local_sha" != "$remote_sha" ]; then
  echo "Local $branch ($local_sha) differs from origin ($remote_sha); push first." >&2; exit 2
fi

if [ "$scope" = windows ]; then workflow=flutter-rust-faber.yml; else workflow=ci.yml; fi
existing="$(gh run list -R "$repo" -w "$workflow" -b "$branch" -e workflow_dispatch -L 50 --json databaseId --jq '.[].databaseId')"

args=(--ref "$branch")
if [ "$workflow" = ci.yml ]; then
  args+=(-f "scope=$scope" -f "test_filter=$filter")
  if [ "$scope" = auto ]; then
    args+=(-f "base_sha=$(gh api "repos/$repo/commits/master" --jq .sha)")
  fi
fi
echo "Dispatching $workflow on $branch @ ${remote_sha:0:12} (scope=$scope${filter:+, filter=$filter})"
gh workflow run "$workflow" -R "$repo" "${args[@]}" || { echo "Dispatch failed (is the branch based on a master with the ci.yml 'scope' input?)" >&2; exit 3; }

run_id=""
for _ in $(seq 1 30); do
  sleep 4
  for id in $(gh run list -R "$repo" -w "$workflow" -b "$branch" -e workflow_dispatch -L 50 --json databaseId --jq '.[].databaseId'); do
    if ! grep -qx "$id" <<<"$existing"; then run_id="$id"; break 2; fi
  done
done
[ -n "$run_id" ] || { echo "Dispatched run did not appear" >&2; exit 3; }
url="https://github.com/$repo/actions/runs/$run_id"
echo "Run: $url"

deadline=$(( $(date +%s) + timeout_min * 60 )); delay=15; last=""
while :; do
  state="$(gh run view "$run_id" -R "$repo" --json status,conclusion --jq '.status + " " + (.conclusion // "")')" || state="$last"
  progress="$(gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" --jq '[.jobs[] | select(.status == "completed")] | length as $d | "\($d)/\(.jobs | length) jobs done"' 2>/dev/null || true)"
  [ "$state $progress" != "$last" ] && echo "$(date +%H:%M:%S) ${state% } ($progress)"
  last="$state $progress"
  case "$state" in completed*) break ;; esac
  [ "$(date +%s)" -lt "$deadline" ] || { echo "Timed out after ${timeout_min} min; run still going: $url" >&2; exit 3; }
  sleep "$delay"; [ "$delay" -lt 60 ] && delay=$(( delay + 15 ))
done

GH_REPO="$repo" bash "$here/ci_branch_evidence_report.sh" "$run_id"
conclusion="$(gh run view "$run_id" -R "$repo" --json conclusion --jq .conclusion)"
echo
echo "RESULT: $conclusion  $url  (head $remote_sha)"
[ "$conclusion" = success ]
