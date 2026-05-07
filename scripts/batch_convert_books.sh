#!/usr/bin/env bash
# Batch convert all books in ~/Downloads/livros/, smallest first.
# Strict mode: stops at the FIRST conversion or validation failure so the
# operator can fix the app, then re-runs from where we left off (failures
# stay in the source dir, successes are removed).
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

# Resolve the most recently modified output dir as the one we just produced.
resolve_output_dir() {
  python3 scripts/_resolve_output_dir.py 2>/dev/null
}

# Build size-sorted list of remaining books (smallest first).
BOOKS=()
while IFS= read -r line; do
  [ -n "$line" ] && BOOKS+=("$line")
done < <(python3 scripts/_list_books_by_size.py "$SRC_DIR")
TOTAL=${#BOOKS[@]}
log "=== batch start: $TOTAL books (smallest first, strict-stop) ==="

for ((i=0; i<TOTAL; i++)); do
  book="${BOOKS[$i]}"
  BOOK_PATH="$SRC_DIR/$book"
  [ ! -f "$BOOK_PATH" ] && { log "SKIP (gone): $book"; continue; }

  SIZE_KB=$(( $(stat -f%z "$BOOK_PATH" 2>/dev/null || stat -c%s "$BOOK_PATH") / 1024 ))
  SAFE_NAME=$(echo "$book" | tr -c '[:alnum:].-' '_' | cut -c1-60)
  BOOK_LOG="$LOG_DIR/${SAFE_NAME}.log"
  : > "$BOOK_LOG"

  log "[$((i+1))/$TOTAL] (${SIZE_KB} KB) → converting: $book"
  START=$(date +%s)

  # First convert pass. If output already exists from a prior run with
  # an empty text cache, force a clean re-synthesis so validation has
  # the cache it needs to compare against the EPUB source of truth.
  CLEAR_FLAG=""
  if [ -d "output" ]; then
    # Check if any cache dir for this book is populated already.
    if ! python3 -c "
import sys, re
from pathlib import Path
stem = Path(sys.argv[1]).stem.lower()
tokens = [t for t in re.split(r'\W+', stem) if len(t) >= 4]
for cache_dir in Path('.cache').iterdir():
    if not cache_dir.is_dir():
        continue
    name = cache_dir.name.lower()
    if stem in name or name in stem or (
        tokens and sum(1 for t in tokens if t in name) / len(tokens) >= 0.6
    ):
        for sub in ('text', 'txt'):
            for d in cache_dir.rglob(sub):
                if d.is_dir() and any(d.iterdir()):
                    sys.exit(0)
sys.exit(1)
" "$BOOK_PATH" 2>/dev/null; then
      CLEAR_FLAG="--clear-cache"
      log "  ⚠ no populated cache — forcing --clear-cache"
    fi
  fi

  if ! python -m python_app.main convert "$BOOK_PATH" \
       --validate-audio --auto-validate-output $CLEAR_FLAG </dev/null >> "$BOOK_LOG" 2>&1; then
    ELAPSED=$(( $(date +%s) - START ))
    log "  ✗ CONVERSION FAILED (${ELAPSED}s) — STOPPING BATCH FOR FIX"
    echo "$book" >> "$FAIL_LIST"
    log "  see: $BOOK_LOG"
    log "=== batch HALTED at book $((i+1))/$TOTAL ==="
    exit 1
  fi

  ELAPSED=$(( $(date +%s) - START ))
  log "  ✓ converted (${ELAPSED}s) — running verify"

  OUTPUT_DIR=$(resolve_output_dir "$BOOK_PATH")
  if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
    log "  ✗ OUTPUT DIR NOT FOUND — STOPPING BATCH"
    echo "$book" >> "$FAIL_LIST"
    log "=== batch HALTED at book $((i+1))/$TOTAL ==="
    exit 1
  fi

  if ! python validate_conversion.py "$BOOK_PATH" --output-dir "$OUTPUT_DIR" </dev/null >> "$BOOK_LOG" 2>&1; then
    log "  ✗ VERIFY FAILED — STOPPING BATCH FOR FIX"
    echo "$book" >> "$FAIL_LIST"
    log "  output: $OUTPUT_DIR"
    log "  see: $BOOK_LOG"
    log "=== batch HALTED at book $((i+1))/$TOTAL ==="
    exit 1
  fi

  log "  ✓ verify 100% — removing source"
  echo "$book" >> "$SUCCESS_LIST"
  rm -f "$BOOK_PATH"
done

log "=== batch complete: all $TOTAL books converted 100% ==="
log "  success: $(wc -l < "$SUCCESS_LIST") books"
log "  failed:  $(wc -l < "$FAIL_LIST") books"
