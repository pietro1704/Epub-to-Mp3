#!/usr/bin/env bash
# Hook: SessionStart
# Shows a summary of recent conversions when Claude Code session begins.
# Reads conversions.jsonl and active jobs; injects as additionalContext.

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"
JOBS_DIR="$PROJECT_DIR/.jobs"

lines=""

# ── Auto-trim log if it exceeds 1000 entries ─────────────────────────────────
if [[ -f "$LOG_FILE" ]]; then
    log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [[ "$log_lines" -gt 1000 ]]; then
        python3 - "$LOG_FILE" <<'PYEOF'
import sys, json
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
if len(records) > 500:
    with open(path, "w", encoding="utf-8") as f:
        for r in records[-500:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
PYEOF
    fi
fi

# ── Recent conversions ──────────────────────────────────────────────────────
if [[ -f "$LOG_FILE" ]]; then
    # Cap at last 500 lines for speed; count total lines with wc for accuracy
    total_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    recent=$(tail -n 500 "$LOG_FILE")

    counts=$(echo "$recent" | python3 - "$total_lines" <<'PYEOF'
import json, sys
total_lines = int(sys.argv[1])
success = failed = seen = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    seen += 1
    try:
        r = json.loads(line)
        o = r.get("outcome", "")
        if o == "success":
            success += 1
        elif o == "failed":
            failed += 1
    except Exception:
        pass
# Total from wc -l (accurate), success/failed from last 500
print(f"{total_lines} {success} {failed}")
PYEOF
    )
    total=$(echo "$counts" | awk '{print $1}')
    success=$(echo "$counts" | awk '{print $2}')
    failed=$(echo "$counts" | awk '{print $3}')

    lines+="## Recent conversions ($total total | $success ✅ $failed ❌)\n"
    lines+="Last 5:\n"

    # Parse last 5 entries from tail output (no full-file read)
    last5=$(tail -n 5 "$LOG_FILE" | python3 - <<'PYEOF'
import json, sys
records = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            records.append(json.loads(line))
        except Exception:
            pass
for r in records[::-1]:
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
