#!/usr/bin/env bash
# Hook: SessionStart
# Shows a summary of recent conversions when Claude Code session begins.
# Reads conversions.jsonl and active jobs; injects as additionalContext.

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"
JOBS_DIR="$PROJECT_DIR/.jobs"

# Single python3 invocation: auto-trim + stats + last 5 + active jobs + output JSON
python3 - "$LOG_FILE" "$JOBS_DIR" <<'PYEOF'
import json, os, sys

log_file, jobs_dir = sys.argv[1], sys.argv[2]
lines = ""

# ── Auto-trim log if it exceeds 1000 entries ─────────────────────────────────
records = []
if os.path.isfile(log_file):
    try:
        with open(log_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except Exception:
                        pass
        if len(records) > 1000:
            keep = records[-500:]
            with open(log_file, "w", encoding="utf-8") as f:
                for r in keep:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
            records = keep
    except Exception:
        pass

# ── Recent conversions ────────────────────────────────────────────────────────
if records:
    total = len(records)
    success = sum(1 for r in records if r.get("outcome") == "success")
    failed = sum(1 for r in records if r.get("outcome") == "failed")
    lines += f"## Recent conversions ({total} total | {success} ✅ {failed} ❌)\nLast 5:\n"
    for r in reversed(records[-5:]):
        outcome = r.get("outcome", "?")
        icon = "✅" if outcome == "success" else ("❌" if outcome == "failed" else "⚠️")
        title = r.get("book_title", "—")[:45]
        engine = r.get("engine", "?")
        mode = r.get("mode", "?")
        ch = f"{r.get('chapters_converted','?')}/{r.get('chapters_total','?')} ch"
        ts = (r.get("timestamp") or "")[:10]
        lines += f"  {icon} [{ts}] {title} ({engine}, {mode}, {ch})\n"
else:
    lines += f"## Conversions: no log yet ({log_file})\n"

# ── Active jobs ───────────────────────────────────────────────────────────────
if os.path.isdir(jobs_dir):
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
    if active:
        lines += "\n## Active jobs\n" + "\n".join(active) + "\n"

if not lines.strip():
    sys.exit(0)

print(json.dumps({"additionalContext": lines}))
PYEOF
