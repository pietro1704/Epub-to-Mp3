#!/usr/bin/env bash
# Bump version across all manifests, generate changelog, tag and push.
# Usage: ./scripts/bump.sh <major|minor|patch|X.Y.Z>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Resolve new version ───────────────────────────────────────────────────────
# The root Cargo.toml workspace version is the single product version source.
CURRENT=$(ruby -e 'print File.read("Cargo.toml")[/^\[workspace\.package\][^\[]*?^version = "([^"]+)"/m, 1].to_s')
[[ -n "$CURRENT" ]] || { echo "Cannot read [workspace.package] version from Cargo.toml" >&2; exit 1; }
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

# ── Update the Rails gateway VERSION file (mirrors the workspace version) ─────
printf '%s\n' "$NEW" > ruby_app/rails_gateway/VERSION

# ── Mirror it into the Apple and Flutter manifests used by local builds ──────
# The Flutter build number after "+" is kept.
NEW="$NEW" ruby - <<'RUBY'
updated = ENV.fetch("NEW")
{
  "ios/EpubToMp3/project.yml" => /^(\s*MARKETING_VERSION: ")[^"]+(?=")/,
  "flutter_app/pubspec.yaml" => /^(version: )[^+\s]+/,
}.each do |path, pattern|
  text = File.read(path)
  abort("#{path} has no version line") unless text.match?(pattern)
  File.write(path, text.sub(pattern) { "#{Regexp.last_match(1)}#{updated}" })
end
RUBY

# ── Update Cargo.toml and the workspace members recorded in Cargo.lock ────────
CURRENT="$CURRENT" NEW="$NEW" ruby - <<'RUBY'
current = ENV.fetch("CURRENT")
updated = ENV.fetch("NEW")
manifest = File.read("Cargo.toml")
section = manifest[/^\[workspace\.package\][^\[]*/m] or abort("Cargo.toml has no [workspace.package]")
File.write("Cargo.toml", manifest.sub(section, section.sub(/^version = "#{Regexp.escape(current)}"$/, %(version = "#{updated}"))))
members = Dir["{crates,benches,native}/**/Cargo.toml"].filter_map do |path|
  text = File.read(path)
  text[/^name = "([^"]+)"/, 1] if text.match?(/^version\.workspace = true$/)
end
lock = File.read("Cargo.lock")
members.each do |name|
  lock = lock.sub(/^name = "#{Regexp.escape(name)}"\nversion = "#{Regexp.escape(current)}"$/, %(name = "#{name}"\nversion = "#{updated}"))
end
File.write("Cargo.lock", lock)
RUBY

# ── Generate / update CHANGELOG.md ───────────────────────────────────────────
if command -v git-cliff &>/dev/null; then
  git-cliff --tag "v$NEW" -o CHANGELOG.md
  echo "CHANGELOG.md updated"
else
  echo "git-cliff not found — skipping changelog (install via mise or cargo install git-cliff)"
fi

# ── Commit + tag ─────────────────────────────────────────────────────────────
git add \
  ruby_app/rails_gateway/VERSION \
  ios/EpubToMp3/project.yml \
  flutter_app/pubspec.yaml \
  Cargo.toml \
  Cargo.lock \
  CHANGELOG.md 2>/dev/null || true

git commit -m "chore: bump version to $NEW"
git tag "v$NEW"

echo ""
echo "Tagged v$NEW — run 'git push && git push --tags' to trigger release CI"
