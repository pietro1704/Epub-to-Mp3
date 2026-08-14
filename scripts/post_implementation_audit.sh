#!/usr/bin/env bash
# Verify the delivery surface after an implementation has been pushed.
set -euo pipefail

WAIT=false
if [[ "${1:-}" == "--wait" ]]; then
    WAIT=true
    shift
fi

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--wait] [commit-sha]" >&2
    exit 64
fi

SHA="${1:-$(git rev-parse HEAD)}"
REPOSITORY="${GITHUB_REPOSITORY:-pietro1704/Epub-to-Mp3}"
FAILED=0

fail() {
    echo "FAIL: $*" >&2
    FAILED=1
}

count_json() {
    jq 'length'
}

if [[ -n "$(git status --porcelain)" ]]; then
    fail "working tree is not clean"
else
    echo "PASS: working tree is clean"
fi

open_prs="$(gh pr list --repo "$REPOSITORY" --state open --limit 100 --json number 2>/dev/null | count_json)"
if [[ "$open_prs" == "0" ]]; then
    echo "PASS: no open pull requests"
else
    fail "$open_prs open pull request(s) require triage"
fi

open_issues="$(gh issue list --repo "$REPOSITORY" --state open --limit 100 --json number 2>/dev/null | count_json)"
if [[ "$open_issues" == "0" ]]; then
    echo "PASS: no open issues"
else
    fail "$open_issues open issue(s) require triage"
fi

code_scanning="$(gh api -H 'Accept: application/vnd.github+json' \
    "/repos/$REPOSITORY/code-scanning/alerts?state=open&per_page=100" 2>/dev/null | count_json)"
if [[ "$code_scanning" == "0" ]]; then
    echo "PASS: Code Scanning has no open alerts"
else
    fail "$code_scanning open Code Scanning alert(s) require remediation"
fi

dependabot="$(gh api -H 'Accept: application/vnd.github+json' \
    "/repos/$REPOSITORY/dependabot/alerts?state=open&per_page=100" 2>/dev/null | count_json)"
if [[ "$dependabot" == "0" ]]; then
    echo "PASS: Dependabot has no open alerts"
else
    fail "$dependabot open Dependabot alert(s) require remediation"
fi

# A short delay lets GitHub register workflows from a just-completed push.
if [[ "$WAIT" == true ]]; then
    sleep 10
fi

runs="$(gh run list --repo "$REPOSITORY" --commit "$SHA" --limit 100 \
    --json databaseId,name,status,conclusion,url 2>/dev/null)"
run_count="$(printf '%s' "$runs" | count_json)"
if [[ "$run_count" == "0" ]]; then
    fail "no GitHub Actions runs found for $SHA"
elif [[ "$WAIT" == true ]]; then
    while IFS= read -r run_id; do
        gh run watch "$run_id" --repo "$REPOSITORY" --exit-status >/dev/null 2>&1 || true
    done < <(printf '%s' "$runs" | jq -r '.[] | select(.status != "completed") | .databaseId')
    runs="$(gh run list --repo "$REPOSITORY" --commit "$SHA" --limit 100 \
        --json databaseId,name,status,conclusion,url 2>/dev/null)"
fi

unfinished="$(printf '%s' "$runs" | jq '[.[] | select(.status != "completed")] | length')"
failed_runs="$(printf '%s' "$runs" | jq '[.[] | select(.status == "completed" and (.conclusion != "success" and .conclusion != "skipped"))] | length')"
if [[ "$unfinished" == "0" && "$failed_runs" == "0" ]]; then
    echo "PASS: all $run_count GitHub Actions run(s) passed for $SHA"
else
    fail "$unfinished Action run(s) unfinished and $failed_runs failed/cancelled run(s) for $SHA"
    printf '%s\n' "$runs" | jq -r '.[] | select(.status != "completed" or (.conclusion != "success" and .conclusion != "skipped")) | "  - \(.name): \(.status)/\(.conclusion // "pending") \(.url)"' >&2
fi

if [[ "$FAILED" == "0" ]]; then
    echo "Repository hygiene audit passed for $SHA."
else
    exit 1
fi
