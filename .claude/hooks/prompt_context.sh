#!/usr/bin/env bash
# Hook: UserPromptSubmit
# When the user's prompt mentions conversions/jobs, injects live status as context.

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('prompt',''))" 2>/dev/null)

# Only act on conversion-related prompts
if ! echo "$PROMPT" | grep -qiE "conver|job|hf|edge|piper|kokoro|epub|mp3|audio|chapter|capítulo|livro|book"; then
    exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"
JOBS_DIR="$PROJECT_DIR/.jobs"

ctx=""

# Active jobs
if [[ -d "$JOBS_DIR" ]]; then
    jobs_info=$(python3 - "$JOBS_DIR" <<'PYEOF'
import json, os, sys, time
jobs_dir = sys.argv[1]
now = time.time()
rows = []
for name in sorted(os.listdir(jobs_dir)):
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(jobs_dir, name), encoding="utf-8") as f:
            job = json.load(f)
        status = job.get("status", "unknown")
        title = (job.get("bookTitle") or job.get("book_title") or name)[:40]
        engine = job.get("engine", "?")
        pct = job.get("progressPercent") or 0
        mode = job.get("mode", "?")
        ch_done = job.get("chaptersCompleted") or job.get("chapters_completed") or 0
        ch_total = job.get("chaptersTotal") or job.get("chapters_total") or "?"
        icon = {"running": "🔄", "queued": "⏳", "completed": "✅",
                "failed": "❌", "cancelled": "🚫"}.get(status, "❓")
        rows.append(f"  {icon} {title} | {engine} | {mode} | {ch_done}/{ch_total} ch | {pct:.0f}%")
    except Exception:
        pass
for r in rows[:10]:
    print(r)
PYEOF
    )
    if [[ -n "$jobs_info" ]]; then
        ctx+="### Current jobs\n$jobs_info\n"
    fi
fi

# Last conversion from log
if [[ -f "$LOG_FILE" ]]; then
    last=$(python3 - "$LOG_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
last = None
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                last = json.loads(line)
            except Exception:
                pass
if last:
    outcome = last.get("outcome", "?")
    icon = "✅" if outcome == "success" else ("❌" if outcome == "failed" else "⚠️")
    title = last.get("book_title", "—")
    engine = last.get("engine", "?")
    mode = last.get("mode", "?")
    ch = f"{last.get('chapters_converted','?')}/{last.get('chapters_total','?')}"
    ts = (last.get("timestamp") or "")[:19].replace("T", " ")
    dur = last.get("duration_seconds", 0)
    dur_str = f"{int(dur//60)}m{int(dur%60)}s" if dur >= 60 else f"{dur:.0f}s"
    print(f"{icon} Last: \"{title}\" | {engine} | {mode} | {ch} ch | {dur_str} | {ts}")
PYEOF
    )
    if [[ -n "$last" ]]; then
        ctx+="### Last completed conversion\n$last\n"
    fi
fi

if [[ -z "$ctx" ]]; then
    exit 0
fi

python3 -c "
import json, sys
ctx = sys.argv[1]
print(json.dumps({'additionalContext': '## Live conversion status\n' + ctx}))
" "$ctx"
