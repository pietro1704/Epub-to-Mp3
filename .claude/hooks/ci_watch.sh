#!/usr/bin/env bash
# Hook: PostToolUse (Bash) — async
# After a git push, waits for the CI run to complete and injects the result.
# If CI fails, includes the failing step and error so Claude can fix it.

INPUT=$(cat)

# Fast pre-filter: only activate on git push commands
if ! echo "$INPUT" | grep -qE '"git push|git push'; then
    exit 0
fi

# Confirm via JSON parsing that it is actually a git push
if ! python3 -c "
import json, sys, re
try:
    d = json.loads(sys.stdin.read())
    cmd = d.get('tool_input', {}).get('command', '')
    sys.exit(0 if re.search(r'git push', cmd) else 1)
except Exception:
    sys.exit(1)
" <<<"$INPUT" 2>/dev/null; then
    exit 0
fi

# Resolve the exact commit pushed from this checkout. Never watch the latest
# master run: a feature-branch push can otherwise report unrelated CI.
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
if [[ -z "$SHA" ]]; then
    echo '{"additionalContext": "## CI Monitor\nCould not resolve the pushed commit SHA. Check GitHub Actions manually."}'
    exit 0
fi

# Wait a moment for GitHub to register the push.
sleep 8

<<<<<<< HEAD
SHA=$(git rev-parse HEAD 2>/dev/null || true)
if [[ -z "$SHA" ]]; then
||||||| e1d1565d6e
# Get the latest run ID for master CI triggered by push
RUN_ID=$(gh run list --branch master --workflow CI --event push --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
if [[ -z "$RUN_ID" ]]; then
    echo '{"additionalContext": "## CI Monitor\nCould not find a CI run after push. Check GitHub Actions manually."}'
=======
# Get the CI run triggered by this exact pushed commit.
RUN_ID=$(gh run list --commit "$SHA" --workflow CI --event push --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
if [[ -z "$RUN_ID" ]]; then
    python3 -c "
import json, sys
print(json.dumps({'additionalContext': '## CI Monitor\nCould not find a CI run for pushed commit ' + sys.argv[1] + '. Check GitHub Actions manually.'}))
" "$SHA"
>>>>>>> origin/chore/repository-trust
    exit 0
fi

if OUTPUT=$("$(dirname "$0")/../../scripts/post_implementation_audit.sh" --wait "$SHA" 2>&1); then
    python3 -c "
import json, sys
print(json.dumps({'additionalContext': '## Delivery hygiene\n✅ ' + sys.argv[1]}))
" "$OUTPUT"
else
    python3 -c "
import json, sys
print(json.dumps({'additionalContext': '## Delivery hygiene\n❌ ' + sys.argv[1]}))
" "$OUTPUT"
fi
