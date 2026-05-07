#!/usr/bin/env bash
# Batch convert all books in ~/Downloads/livros/, validate, remove on 100% pass.
# Iterates until source dir is empty or only failures remain.
set -uo pipefail

cd "$(dirname "$0")/.."
source .venv/bin/activate

SRC_DIR="$HOME/Downloads/livros"
LOG_DIR=".logs/batch"
mkdir -p "$LOG_DIR"

MASTER_LOG="$LOG_DIR/master_$(date +%Y%m%d_%H%M%S).log"
SUCCESS_LIST="$LOG_DIR/success.txt"
FAIL_LIST="$LOG_DIR/fail.txt"
touch "$SUCCESS_LIST" "$FAIL_LIST"

log() {
  echo "[$(date +'%H:%M:%S')] $*" | tee -a "$MASTER_LOG"
}

# Resolve final output dir for a given EPUB by reading the latest mtime under output/
# matching the book stem. Falls back to scanning all directories.
resolve_output_dir() {
  local book_path="$1"
  local stem
  stem=$(basename "$book_path" | sed -E 's/\.[^.]+$//')
  python - "$book_path" <<'PY' 2>/dev/null
import sys, os, glob
from pathlib import Path

src = Path(sys.argv[1])
output_root = Path("output")
if not output_root.is_dir():
    print("")
    sys.exit(0)

# Newest output dir overall is most likely the one we just produced.
candidates = [p for p in output_root.iterdir() if p.is_dir()]
if not candidates:
    print("")
    sys.exit(0)

candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
print(candidates[0])
PY
}

BOOKS=()
while IFS= read -r line; do
  [ -n "$line" ] && BOOKS+=("$line")
done < <(ls "$SRC_DIR" 2>/dev/null | grep -E '\.(epub|pdf)$' || true)
TOTAL=${#BOOKS[@]}
log "=== batch start: $TOTAL books ==="

for ((i=0; i<TOTAL; i++)); do
  book="${BOOKS[$i]}"
  BOOK_PATH="$SRC_DIR/$book"
  [ ! -f "$BOOK_PATH" ] && { log "SKIP (gone): $book"; continue; }

  SAFE_NAME=$(echo "$book" | tr -c '[:alnum:].-' '_' | cut -c1-60)
  BOOK_LOG="$LOG_DIR/${SAFE_NAME}.log"
  : > "$BOOK_LOG"

  log "[$((i+1))/$TOTAL] → converting: $book"
  START=$(date +%s)

  if python -m python_app.main convert "$BOOK_PATH" \
       --validate-audio --auto-validate-output </dev/null >> "$BOOK_LOG" 2>&1; then
    ELAPSED=$(( $(date +%s) - START ))
    log "  ✓ converted ($ELAPSED s) — running verify"

    OUTPUT_DIR=$(resolve_output_dir "$BOOK_PATH")
    if [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
      if python validate_conversion.py "$BOOK_PATH" "$OUTPUT_DIR" </dev/null >> "$BOOK_LOG" 2>&1; then
        log "  ✓ verify 100% — removing source"
        echo "$book" >> "$SUCCESS_LIST"
        rm -f "$BOOK_PATH"
      else
        log "  ✗ verify failed (kept source) — output: $OUTPUT_DIR"
        echo "$book" >> "$FAIL_LIST"
      fi
    else
      log "  ✗ output dir not found (kept source)"
      echo "$book" >> "$FAIL_LIST"
    fi
  else
    ELAPSED=$(( $(date +%s) - START ))
    log "  ✗ conversion failed ($ELAPSED s) — see $BOOK_LOG"
    echo "$book" >> "$FAIL_LIST"
  fi
done

log "=== batch end ==="
log "  success: $(wc -l < "$SUCCESS_LIST") books"
log "  failed:  $(wc -l < "$FAIL_LIST") books"
log "  remaining in src: $(ls "$SRC_DIR" 2>/dev/null | grep -cE '\.(epub|pdf)$')"
