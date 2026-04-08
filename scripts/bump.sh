#!/usr/bin/env bash
# Bump version across all manifests, generate changelog, tag and push.
# Usage: ./scripts/bump.sh <major|minor|patch|X.Y.Z>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Resolve new version ───────────────────────────────────────────────────────
CURRENT=$(python3 -c "import json; print(json.load(open('desktop/src-tauri/tauri.conf.json'))['version'])")
BUMP="${1:-patch}"

if [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW="$BUMP"
else
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
  case "$BUMP" in
    major) NEW="$((MAJOR + 1)).0.0" ;;
    minor) NEW="${MAJOR}.$((MINOR + 1)).0" ;;
    patch) NEW="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    *)
      echo "Usage: bump.sh <major|minor|patch|X.Y.Z>" >&2
      exit 1
      ;;
  esac
fi

echo "Bumping $CURRENT → $NEW"

# ── Update tauri.conf.json ────────────────────────────────────────────────────
python3 - "$NEW" <<'PYEOF'
import json, sys
path = "desktop/src-tauri/tauri.conf.json"
d = json.load(open(path))
d["version"] = sys.argv[1]
json.dump(d, open(path, "w"), indent=2)
open(path, "a").write("\n")
PYEOF

# ── Update Cargo.toml ─────────────────────────────────────────────────────────
sed -i.bak "0,/^version = \".*\"/{s/^version = \".*\"/version = \"$NEW\"/}" \
  desktop/src-tauri/Cargo.toml
rm -f desktop/src-tauri/Cargo.toml.bak

# ── Update web/package.json ──────────────────────────────────────────────────
sed -i.bak "s/\"version\": \".*\"/\"version\": \"$NEW\"/" web/package.json
rm -f web/package.json.bak

# ── Update python_app/version.py ─────────────────────────────────────────────
sed -i.bak "s/__version__ = \".*\"/__version__ = \"$NEW\"/" python_app/version.py
rm -f python_app/version.py.bak

# ── Update Cargo.lock (keep in sync) ─────────────────────────────────────────
if command -v cargo &>/dev/null; then
  (cd desktop/src-tauri && cargo update --workspace --quiet 2>/dev/null || true)
fi

# ── Update metainfo.xml release entry ────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
sed -i.bak "s|<release version=\".*\" date=\".*\"/>|<release version=\"$NEW\" date=\"$TODAY\"/>|" \
  flatpak/io.github.pietro1704.EpubToMp3.metainfo.xml
rm -f flatpak/io.github.pietro1704.EpubToMp3.metainfo.xml.bak

# ── Generate / update CHANGELOG.md ───────────────────────────────────────────
if command -v git-cliff &>/dev/null; then
  git-cliff --tag "v$NEW" -o CHANGELOG.md
  echo "CHANGELOG.md updated"
else
  echo "git-cliff not found — skipping changelog (install via mise or cargo install git-cliff)"
fi

# ── Commit + tag ─────────────────────────────────────────────────────────────
git add \
  desktop/src-tauri/tauri.conf.json \
  desktop/src-tauri/Cargo.toml \
  web/package.json \
  python_app/version.py \
  flatpak/io.github.pietro1704.EpubToMp3.metainfo.xml \
  CHANGELOG.md 2>/dev/null || true

git commit -m "chore: bump version to $NEW"
git tag "v$NEW"

echo ""
echo "Tagged v$NEW — run 'git push && git push --tags' to trigger release CI"
