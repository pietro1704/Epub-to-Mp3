#!/usr/bin/env bash
# Hook: UserPromptSubmit
# When the user's prompt mentions conversions/jobs, injects live status as context.

INPUT=$(cat)

# Fast pre-filter on raw JSON — avoids python3 startup for unrelated prompts
if ! echo "$INPUT" | grep -qiE "conver|job|hf|edge|piper|kokoro|epub|mp3|audio|chapter|cap.tulo|livro|book"; then
    exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"
JOBS_DIR="$PROJECT_DIR/.jobs"

# Single python3 invocation: extract prompt, verify filter, read jobs + log, format output
python3 - "$INPUT" "$JOBS_DIR" "$LOG_FILE" <<'PYEOF'
import json, os, re, sys

raw_input, jobs_dir, log_file = sys.argv[1], sys.argv[2], sys.argv[3]

# Parse prompt and confirm it's conversion-related
try:
    d = json.loads(raw_input)
    prompt = d.get("prompt", "")
except Exception:
    sys.exit(0)

KEYWORDS = re.compile(
    r"conver|job|hf|edge|piper|kokoro|epub|mp3|audio|chapter|cap[íi]tulo|livro|book",
    re.IGNORECASE,
)
if not KEYWORDS.search(prompt):
    sys.exit(0)

ctx = ""

# Active jobs
if os.path.isdir(jobs_dir):
    rows = []
    for name in sorted(os.listdir(jobs_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(jobs_dir, name), encoding="utf-8") as f:
                job = json.load(f)
            # Job files use "state" not "status"
            state = job.get("state", "unknown")
            title = (job.get("bookTitle") or job.get("book_title") or name)[:40]
            engine = job.get("engine", "?")
            pct = job.get("progressPercent") or 0
            mode = job.get("mode", "?")
            ch_done = job.get("chaptersCompleted") or job.get("chapters_completed") or 0
            ch_total = job.get("chaptersTotal") or job.get("chapters_total") or "?"
            icon = {"running": "🔄", "queued": "⏳", "finished": "✅",
                    "failed": "❌", "cancelled": "🚫"}.get(state, "❓")
            rows.append(f"  {icon} {title} | {engine} | {mode} | {ch_done}/{ch_total} ch | {pct:.0f}%")
        except Exception:
            pass
    if rows:
        ctx += "### Current jobs\n" + "\n".join(rows[:10]) + "\n"

# Last conversion from log
if os.path.isfile(log_file):
    try:
        with open(log_file, encoding="utf-8") as f:
            # Read only the last 10 lines efficiently
            lines = f.readlines()[-10:]
        last = None
        for line in lines:
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
            ctx += f"### Last completed conversion\n{icon} Last: \"{title}\" | {engine} | {mode} | {ch} ch | {dur_str} | {ts}\n"
    except Exception:
        pass

if not ctx:
    sys.exit(0)

print(json.dumps({"additionalContext": "## Live conversion status\n" + ctx}))
PYEOF
