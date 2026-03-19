#!/usr/bin/env bash
# Hook: Stop
# When Claude finishes responding, warns if there are active/stuck jobs.

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS_DIR="$PROJECT_DIR/.jobs"

if [[ ! -d "$JOBS_DIR" ]]; then
    exit 0
fi

warning=$(python3 - "$JOBS_DIR" <<'PYEOF'
import json, os, sys, time
jobs_dir = sys.argv[1]
now = time.time()
running = []
for name in os.listdir(jobs_dir):
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(jobs_dir, name), encoding="utf-8") as f:
            job = json.load(f)
        # Job files use "state" not "status"
        state = job.get("state", "")
        if state == "queued":
            title = (job.get("bookTitle") or job.get("book_title") or name)[:40]
            engine = job.get("engine", "?")
            running.append(f"  ⏳ {title} [{engine}] queued")
        elif state == "running":
            title = (job.get("bookTitle") or job.get("book_title") or name)[:40]
            engine = job.get("engine", "?")
            pct = job.get("progressPercent") or 0
            # _lastActivityTs is a Unix float persisted by _update_job_activity
            last_ts_float = job.get("_lastActivityTs")
            stall = ""
            if last_ts_float:
                try:
                    elapsed = now - float(last_ts_float)
                    if elapsed > 3600:
                        # Dead job: server crashed without updating state — skip
                        continue
                    if elapsed > 300:
                        stall = f" ⚠️ stalled {int(elapsed//60)}m ago"
                except Exception:
                    pass
            running.append(f"  🔄 {title} [{engine}] {pct:.0f}%{stall}")
    except Exception:
        pass
if running:
    print("## Active jobs still running:")
    for r in running:
        print(r)
PYEOF
)

if [[ -n "$warning" ]]; then
    # Block the stop with a reminder about active jobs
    python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'decision': 'block', 'reason': msg}))
" "$warning"
fi
