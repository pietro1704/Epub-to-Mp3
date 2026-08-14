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

SHA=$(git rev-parse HEAD 2>/dev/null || true)
if [[ -z "$SHA" ]]; then
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
