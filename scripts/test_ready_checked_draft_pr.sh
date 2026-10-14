#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'pr ready' ]]; then
  touch "$READY_MARKER"
elif [[ "$1" == api ]]; then
  printf '{"status":"completed","conclusion":"%s"}\n' "$CI_CONCLUSION"
elif [[ "$*" == *statusCheckRollup* ]]; then
  echo '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
elif [[ "$*" == *'--jq .headRefOid'* ]]; then
  echo "${CURRENT_HEAD:-verified-head}"
else
  echo '{"author":{"login":"owner"},"baseRefName":"master","headRepository":{"nameWithOwner":"owner/repo"},"headRefOid":"verified-head","isDraft":true,"mergeStateStatus":"CLEAN"}'
fi
MOCK
chmod +x "$fixture/gh"
export PATH="$fixture:$PATH" REPO=owner/repo DRAFT_PR=793 READY_MARKER="$fixture/ready"
CI_CONCLUSION=success bash ready_checked_draft_pr.sh >/dev/null
[[ -f "$READY_MARKER" ]]
rm "$READY_MARKER"
if CI_CONCLUSION=failure bash ready_checked_draft_pr.sh >/dev/null 2>&1; then exit 1; fi
[[ ! -f "$READY_MARKER" ]]
if CI_CONCLUSION=success CURRENT_HEAD=changed-head bash ready_checked_draft_pr.sh >/dev/null 2>&1; then exit 1; fi
[[ ! -f "$READY_MARKER" ]]
if DRAFT_PR=invalid CI_CONCLUSION=success bash ready_checked_draft_pr.sh >/dev/null 2>&1; then exit 1; fi
[[ ! -f "$READY_MARKER" ]]
echo 'Checked draft delivery: 4 cases passed.'
