#!/usr/bin/env bash
# Hook: PostToolUse (Bash)
# After running conversion commands (mise run convert / python -m python_app.main),
# injects the final result from conversions.jsonl as feedback to Claude.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('command', ''))
" 2>/dev/null)

# Only act on conversion-related commands
if ! echo "$COMMAND" | grep -qE "python.*main.*convert|mise run (convert|web)|python_app\.main"; then
    exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
    exit 0
fi

# Read last entry written after the command
result=$(python3 - "$LOG_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
records = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except Exception:
                pass
if not records:
    sys.exit(0)
r = records[-1]
outcome = r.get("outcome", "?")
icon = "✅" if outcome == "success" else ("❌" if outcome == "failed" else "⚠️")
title = r.get("book_title", "—")
engine = r.get("engine", "?")
mode = r.get("mode", "?")
ch_ok = r.get("chapters_converted", 0)
ch_fail = r.get("chapters_failed", 0)
ch_total = r.get("chapters_total", 0)
dur = r.get("duration_seconds", 0)
dur_str = f"{int(dur//60)}m{int(dur%60)}s" if dur >= 60 else f"{dur:.0f}s"
voice = r.get("voice", "")
print(f"{icon} Conversion {outcome}: \"{title}\"")
print(f"   Engine: {engine}  |  Mode: {mode}  |  Voice: {voice}")
print(f"   Chapters: {ch_ok} ok / {ch_fail} failed / {ch_total} total  |  Time: {dur_str}")
PYEOF
)

if [[ -n "$result" ]]; then
    python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'additionalContext': '## Conversion result\n' + msg}))
" "$result"
fi
