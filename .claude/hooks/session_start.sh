#!/usr/bin/env bash
# Hook: SessionStart
# Shows a summary of recent conversions when Claude Code session begins.
# Reads conversions.jsonl and active jobs; injects as additionalContext.

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"
JOBS_DIR="$PROJECT_DIR/.jobs"

lines=""

# ── Recent conversions ──────────────────────────────────────────────────────
if [[ -f "$LOG_FILE" ]]; then
    counts=$(python3 - "$LOG_FILE" <<'PYEOF'
import json, sys
total = success = failed = 0
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        total += 1
        try:
            r = json.loads(line)
            o = r.get("outcome", "")
            if o == "success":
                success += 1
            elif o == "failed":
                failed += 1
        except Exception:
            pass
print(f"{total} {success} {failed}")
PYEOF
    )
    total=$(echo "$counts" | awk '{print $1}')
    success=$(echo "$counts" | awk '{print $2}')
    failed=$(echo "$counts" | awk '{print $3}')

    lines+="## Recent conversions ($total total | $success ✅ $failed ❌)\n"
    lines+="Last 5:\n"

    # Parse last 5 entries with python for reliable JSON handling
    last5=$(python3 - "$LOG_FILE" <<'PYEOF'
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
for r in records[-5:][::-1]:
    outcome = r.get("outcome", "?")
    icon = "✅" if outcome == "success" else ("❌" if outcome == "failed" else "⚠️")
    title = r.get("book_title", "—")[:45]
    engine = r.get("engine", "?")
    mode = r.get("mode", "?")
    ch = f"{r.get('chapters_converted','?')}/{r.get('chapters_total','?')} ch"
    ts = (r.get("timestamp") or "")[:10]
    print(f"  {icon} [{ts}] {title} ({engine}, {mode}, {ch})")
PYEOF
    )
    lines+="$last5\n"
else
    lines+="## Conversions: no log yet ($LOG_FILE)\n"
fi

# ── Active jobs ──────────────────────────────────────────────────────────────
if [[ -d "$JOBS_DIR" ]]; then
    active=$(python3 - "$JOBS_DIR" <<'PYEOF'
import json, os, sys
jobs_dir = sys.argv[1]
active = []
for name in os.listdir(jobs_dir):
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(jobs_dir, name), encoding="utf-8") as f:
            job = json.load(f)
        status = job.get("status", "")
        if status in ("running", "queued", "pending"):
            title = job.get("bookTitle") or job.get("book_title") or name
            engine = job.get("engine", "?")
            pct = job.get("progressPercent", 0)
            active.append(f"  🔄 {title[:40]} [{engine}] {pct:.0f}%")
    except Exception:
        pass
for line in active:
    print(line)
PYEOF
    )
    if [[ -n "$active" ]]; then
        lines+="\n## Active jobs\n$active\n"
    fi
fi

if [[ -z "$lines" ]]; then
    exit 0
fi

# Output additionalContext so Claude receives the conversion summary
python3 -c "
import json, sys
ctx = sys.argv[1]
print(json.dumps({'additionalContext': ctx}))
" "$lines"
