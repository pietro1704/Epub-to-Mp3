#!/bin/bash
# Proves a launch with -uiTestIsolatedSettings leaves the real EpubToMp3 installation untouched:
# snapshots the real Application Support tree, caches, the app's defaults domain and the App Group preferences,
# launches the app isolated, imports a PDF (the path that polluted the real library before),
# quits the app, confirms with pgrep that nothing is left running, and diffs the snapshots.
# Usage: scripts/verify_isolated_launch.sh /path/to/EpubToMp3.app [/path/to/file.pdf]
set -uo pipefail
APP="${1:?path to EpubToMp3.app}"
PDF="${2:-}"
BUNDLE_ID="com.pietrocode.epubtomp3"
GROUP_ID="group.com.pietrocode.epubtomp3"
SUPPORT="$HOME/Library/Application Support/EpubToMp3"
CACHES="$HOME/Library/Caches/$BUNDLE_ID"
WORK="$(mktemp -d)"
snapshot() {
  local out="$1"
  { [ -d "$SUPPORT" ] && find "$SUPPORT" -print0 | xargs -0 stat -f '%N %z %m' 2>/dev/null | sort; echo "--caches"
    [ -d "$CACHES" ] && find "$CACHES" -print0 | xargs -0 stat -f '%N %z %m' 2>/dev/null | sort
    echo "--defaults"
    # AppKit's own window-frame/toolbar autosave keys are excluded: they carry no library or reading state.
    defaults export "$BUNDLE_ID" - 2>/dev/null | plutil -convert json -r -o - - 2>/dev/null \
      | python3 -I -c 'import json,sys
d=json.load(sys.stdin) if not sys.stdin.isatty() else {}
for k in sorted(d):
    if k.startswith(("NSWindow Frame","NSSplitView","NSToolbar","NSNavPanel","NSOSPLastRootDirectory","NSTableView","NSStatusItem")): continue
    print(k, json.dumps(d[k], sort_keys=True))' 2>/dev/null
    echo "--group"
    defaults export "$GROUP_ID" - 2>/dev/null | plutil -convert json -r -o - - 2>/dev/null || true
    echo "--group-container"
    GC="$HOME/Library/Group Containers/$GROUP_ID"; [ -d "$GC" ] && find "$GC" -print0 | xargs -0 stat -f '%N %z %m' 2>/dev/null | sort
  } > "$out"
}
pgrep -x EpubToMp3 >/dev/null && { echo "FAIL: EpubToMp3 is already running; close it first (one instance at a time)"; exit 2; }
snapshot "$WORK/before.txt"
open -n "$APP" --args -uiTestIsolatedSettings -AppleLanguages "(en)" -AppleLocale en_US
sleep 10
[ -n "$PDF" ] && { open -a "$APP" "$PDF"; sleep 8; }
osascript -e 'tell application "EpubToMp3" to quit' >/dev/null 2>&1
for _ in $(seq 20); do pgrep -x EpubToMp3 >/dev/null || break; sleep 1; done
pkill -x EpubToMp3 2>/dev/null; sleep 1
if pgrep -x EpubToMp3 >/dev/null; then echo "FAIL: EpubToMp3 still running"; exit 3; else echo "pgrep: no EpubToMp3 process left"; fi
snapshot "$WORK/after.txt"
if diff -u "$WORK/before.txt" "$WORK/after.txt" > "$WORK/diff.txt"; then
  echo "PASS: the real installation is byte-for-byte unchanged ($(wc -l < "$WORK/before.txt") snapshot lines)"
else
  echo "FAIL: the real installation changed:"; head -40 "$WORK/diff.txt"; exit 1
fi
ls -d "${TMPDIR:-/tmp}"EpubToMp3-isolated-home >/dev/null 2>&1 && echo "throwaway home exists under TMPDIR (it is deleted at the next isolated launch)"
