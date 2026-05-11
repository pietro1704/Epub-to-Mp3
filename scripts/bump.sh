#!/usr/bin/env bash
# Bump version across all manifests, generate changelog, tag and push.
# Usage: ./scripts/bump.sh <major|minor|patch|X.Y.Z>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Resolve new version ───────────────────────────────────────────────────────
CURRENT=$(python3 -c "
import re
text = open('python_app/version.py').read()
print(re.search(r'__version__ = \"(.+)\"', text).group(1))
")
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

# ── Update web/package.json ──────────────────────────────────────────────────
sed -i.bak "s/\"version\": \".*\"/\"version\": \"$NEW\"/" web/package.json
rm -f web/package.json.bak

# ── Update python_app/version.py ─────────────────────────────────────────────
sed -i.bak "s/__version__ = \".*\"/__version__ = \"$NEW\"/" python_app/version.py
rm -f python_app/version.py.bak

# ── Generate / update CHANGELOG.md ───────────────────────────────────────────
if command -v git-cliff &>/dev/null; then
  git-cliff --tag "v$NEW" -o CHANGELOG.md
  echo "CHANGELOG.md updated"
else
  echo "git-cliff not found — skipping changelog (install via mise or cargo install git-cliff)"
fi

# ── Commit + tag ─────────────────────────────────────────────────────────────
git add \
  web/package.json \
  python_app/version.py \
  CHANGELOG.md 2>/dev/null || true

git commit -m "chore: bump version to $NEW"
git tag "v$NEW"

echo ""
echo "Tagged v$NEW — run 'git push && git push --tags' to trigger release CI"
