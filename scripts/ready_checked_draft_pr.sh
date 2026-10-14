#!/usr/bin/env bash
# Bootstrap the first checked-delivery PR without using the older unchecked merger.
set -euo pipefail
cd "$(dirname "$0")"
[[ "${DRAFT_PR:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid draft PR number.' >&2; exit 2; }
: "${REPO:?Repository is required}"
pr=$(gh pr view "$DRAFT_PR" --repo "$REPO" --json author,baseRefName,headRepository,headRefOid,isDraft,mergeStateStatus)
jq -e --arg owner "${REPO%%/*}" --arg repo "$REPO" \
  '.author.login == $owner and .baseRefName == "master" and .headRepository.nameWithOwner == $repo and .isDraft and .mergeStateStatus != "BEHIND"' \
  <<< "$pr" >/dev/null
head_sha=$(jq -r '.headRefOid' <<< "$pr")
for attempt in {1..60}; do
  current_head=$(gh pr view "$DRAFT_PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
  [[ "$current_head" == "$head_sha" ]] || { echo 'PR head changed; run the automation again.' >&2; exit 1; }
  ci=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$head_sha&per_page=1" --jq '.workflow_runs[0] | {status,conclusion}')
  checks=$(gh pr view "$DRAFT_PR" --repo "$REPO" --json statusCheckRollup --jq '.statusCheckRollup')
  if jq -n --argjson ci "$ci" --argjson checks "$checks" '{ci:$ci,checks:$checks}' | jq -e -f pr_merge_checks_pass.jq >/dev/null; then
    state=$(gh pr view "$DRAFT_PR" --repo "$REPO" --json headRefOid,mergeStateStatus)
    jq -e --arg sha "$head_sha" '.headRefOid == $sha and .mergeStateStatus != "BEHIND"' <<< "$state" >/dev/null
    gh pr ready "$DRAFT_PR" --repo "$REPO"
    echo "PR #$DRAFT_PR is ready after successful checks."
    exit 0
  fi
  if jq -e '.status == "completed" and .conclusion != "success"' <<< "$ci" >/dev/null; then
    echo "CI did not pass; PR #$DRAFT_PR remains draft." >&2
    exit 1
  fi
  echo "PR #$DRAFT_PR is waiting for checked delivery ($attempt/60)."
  sleep 60
done
echo 'Checks did not pass within one hour; PR remains draft.' >&2
exit 1
