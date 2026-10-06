#!/bin/bash
# Keeps Xcode build artifacts for this project bounded on disk-constrained
# Macs. Two independent caps, both oldest-first eviction, applied to:
#   - Xcode DerivedData for THIS project only (dirs named "EpubToMp3-*")
#   - ios/EpubToMp3/.build* directories (per-invocation derivedDataPath dirs)
#
# Never touches other projects' DerivedData or anything outside these two
# locations. Safe to run before every device build/test task.
set -euo pipefail

MAX_AGE_DAYS="${IOS_DISK_GUARD_MAX_AGE_DAYS:-3}"
MAX_TOTAL_MB="${IOS_DISK_GUARD_MAX_TOTAL_MB:-4096}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_ROOT="${IOS_DISK_GUARD_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
IOS_BUILD_DIR="${IOS_DISK_GUARD_IOS_BUILD_DIR:-$REPO_ROOT/ios/EpubToMp3}"

# Removes direct subdirectories of $1 matching glob $2 that are older than
# MAX_AGE_DAYS.
prune_by_age() {
  local parent="$1" glob="$2"
  [[ -d "$parent" ]] || return 0
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name "$glob" -mtime "+${MAX_AGE_DAYS}" -print0 \
    | while IFS= read -r -d '' old; do
        echo "ios_disk_guard: removing (age > ${MAX_AGE_DAYS}d): $old"
        rm -rf "$old"
      done
}

# Evicts oldest-first direct subdirectories of $1 matching glob $2 until
# their combined size is under MAX_TOTAL_MB.
prune_by_total_size() {
  local parent="$1" glob="$2" label="$3"
  [[ -d "$parent" ]] || return 0
  shopt -s nullglob
  local dirs=("$parent"/$glob)
  shopt -u nullglob
  (( ${#dirs[@]} == 0 )) && return 0

  local total_kb=0
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    total_kb=$((total_kb + $(du -sk "$d" 2>/dev/null | cut -f1)))
  done
  local total_mb=$((total_kb / 1024))
  (( total_mb <= MAX_TOTAL_MB )) && return 0

  echo "ios_disk_guard: $label at ${total_mb}MB > cap ${MAX_TOTAL_MB}MB, evicting oldest first"
  local oldest_first
  # `stat -f '%m %N'` is BSD stat (macOS, the primary target for this
  # script); GNU stat (Linux, e.g. CI runners exercising this script via
  # test_ios_disk_guard.py) uses `-c '%Y %n'` instead. Detect via
  # `--version`, a GNU-coreutils-only flag BSD stat rejects — `-f '%m'`
  # itself is NOT a reliable probe: GNU stat's `-f` mode has a DIFFERENT
  # meaning (filesystem status, not custom format) and some versions
  # accept an unrecognised `%m` directive without erroring, silently
  # misdetecting as BSD.
  if stat --version >/dev/null 2>&1; then
    oldest_first=$(for d in "${dirs[@]}"; do stat -c '%Y %n' "$d"; done | sort -n | cut -d' ' -f2-)
  else
    oldest_first=$(for d in "${dirs[@]}"; do stat -f '%m %N' "$d"; done | sort -n | cut -d' ' -f2-)
  fi
  while IFS= read -r d; do
    (( total_mb <= MAX_TOTAL_MB )) && break
    [[ -d "$d" ]] || continue
    local sz_mb=$(( $(du -sk "$d" 2>/dev/null | cut -f1) / 1024 ))
    echo "ios_disk_guard: removing (size cap): $d"
    rm -rf "$d"
    total_mb=$((total_mb - sz_mb))
  done <<< "$oldest_first"
}

prune_by_age "$DERIVED_DATA_ROOT" "EpubToMp3-*"
prune_by_total_size "$DERIVED_DATA_ROOT" "EpubToMp3-*" "project DerivedData"

prune_by_age "$IOS_BUILD_DIR" ".build*"
prune_by_total_size "$IOS_BUILD_DIR" ".build*" ".build* dirs"

echo "ios_disk_guard: done (age cap ${MAX_AGE_DAYS}d, size cap ${MAX_TOTAL_MB}MB per location)"
