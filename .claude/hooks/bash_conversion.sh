#!/usr/bin/env bash
# Hook: PostToolUse (Bash)
# After running conversion commands (mise run convert / python -m python_app.main),
# injects the final result from conversions.jsonl as feedback to Claude.

INPUT=$(cat)

# Fast pre-filter before spawning python3
if ! echo "$INPUT" | grep -qE "python.*main.*convert|mise run (convert|web)|python_app\.main"; then
    exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="$PROJECT_DIR/.logs/conversions.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
    exit 0
fi

# Single python3 invocation: verify command, read log, format + output JSON
python3 - "$INPUT" "$LOG_FILE" <<'PYEOF'
import json, re, sys

raw_input, log_file = sys.argv[1], sys.argv[2]

# Confirm the bash command is conversion-related
try:
    d = json.loads(raw_input)
    command = d.get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)

if not re.search(r"python.*main.*convert|mise run (convert|web)|python_app\.main", command):
    sys.exit(0)

# Read last entry from log
try:
    with open(log_file, encoding="utf-8") as f:
        lines = f.readlines()[-20:]
    last = None
    for line in lines:
        line = line.strip()
        if line:
            try:
                last = json.loads(line)
            except Exception:
                pass
except Exception:
    sys.exit(0)

if not last:
    sys.exit(0)

outcome = last.get("outcome", "?")
icon = "✅" if outcome == "success" else ("❌" if outcome == "failed" else "⚠️")
title = last.get("book_title", "—")
engine = last.get("engine", "?")
mode = last.get("mode", "?")
ch_ok = last.get("chapters_converted", 0)
ch_fail = last.get("chapters_failed", 0)
ch_total = last.get("chapters_total", 0)
dur = last.get("duration_seconds", 0)
dur_str = f"{int(dur//60)}m{int(dur%60)}s" if dur >= 60 else f"{dur:.0f}s"
voice = last.get("voice", "")

msg = (
    f"{icon} Conversion {outcome}: \"{title}\"\n"
    f"   Engine: {engine}  |  Mode: {mode}  |  Voice: {voice}\n"
    f"   Chapters: {ch_ok} ok / {ch_fail} failed / {ch_total} total  |  Time: {dur_str}"
)

# Run analyse-logs and append HIGH issues only — keeps the noise low
# but surfaces real problems (sample-rate mismatches, silent
# fallbacks, language mismatches) without the user having to ask.
import os, subprocess
analyse_lines = []
try:
    project_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(log_file))))
    proc = subprocess.run(
        [sys.executable, os.path.join(project_dir, "scripts", "analyze_logs.py"), "--book", title],
        capture_output=True, text=True, timeout=30, cwd=project_dir,
    )
    if proc.returncode == 0 and proc.stdout:
        # Extract only the HIGH section.
        in_high = False
        for line in proc.stdout.splitlines():
            if line.startswith("## HIGH"):
                in_high = True
                analyse_lines.append(line)
                continue
            if in_high and line.startswith("## "):
                break
            if in_high:
                analyse_lines.append(line)
except Exception:
    pass

if analyse_lines:
    msg += "\n\n## Log analyser — HIGH issues detected\n" + "\n".join(analyse_lines).strip()

print(json.dumps({"additionalContext": "## Conversion result\n" + msg}))
PYEOF
