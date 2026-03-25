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

# Wait a moment for GitHub to register the push
sleep 8

# Get the latest run ID for master CI triggered by push
RUN_ID=$(gh run list --branch master --workflow CI --event push --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
if [[ -z "$RUN_ID" ]]; then
    echo '{"additionalContext": "## CI Monitor\nCould not find a CI run after push. Check GitHub Actions manually."}'
    exit 0
fi

# Wait for the run to finish (up to 12 minutes)
gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1
EXIT_CODE=$?

# Fetch result
RESULT=$(gh run view "$RUN_ID" --json conclusion,name,status,url -q '"CI " + .conclusion + " — " + .url' 2>/dev/null)

if [[ $EXIT_CODE -eq 0 ]]; then
    python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'additionalContext': '## CI result\n✅ ' + msg}))
" "$RESULT"
else
    # Fetch the failing step + first error line
    FAIL_LOG=$(gh run view "$RUN_ID" --log-failed 2>/dev/null \
        | grep -E "error|Error|FAILED|##\[error\]" \
        | grep -v "^test.*PASSED" \
        | head -20)
    python3 -c "
import json, sys
result, log = sys.argv[1], sys.argv[2]
msg = '## CI result\n❌ ' + result + '\n\n### Failing output\n' + ''.join(log.splitlines(keepends=True)[:20])
print(json.dumps({'additionalContext': msg}))
" "$RESULT" "$FAIL_LOG"
fi
