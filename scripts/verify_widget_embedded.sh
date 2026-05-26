#!/usr/bin/env bash
# Regression guard for the iOS widget embed regression closed by slice 18.
#
# In v0.5.x the xcodegen `platforms: [iOS]` filter silently dropped the
# App → Widget dependency from the generated pbxproj, so the production
# .app bundle shipped WITHOUT EpubToMp3Widget.appex inside PlugIns/.
# Users got no widget in the gallery. This script fails fast (exit 2)
# when the regression returns.
#
# Two checks:
#   1. project.yml has the App → EpubToMp3Widget dependency with embed.
#   2. After `xcodegen generate`, pbxproj has both a PBXTargetDependency
#      pointing at the widget AND an `Embed Foundation Extensions`
#      copy-files phase that lists the .appex.
#
# Designed to run inside the CI job that already builds the Apple
# targets, before the actual xcodebuild step.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="${ROOT}/ios/EpubToMp3/project.yml"
PBXPROJ="${ROOT}/ios/EpubToMp3/EpubToMp3.xcodeproj/project.pbxproj"

if [[ ! -f "${PROJECT_YML}" ]]; then
  echo "error: project.yml missing at ${PROJECT_YML}" >&2
  exit 2
fi

if ! grep -A 3 "target: EpubToMp3Widget" "${PROJECT_YML}" | grep -q "embed: true"; then
  echo "error: project.yml is missing the App → EpubToMp3Widget embed dependency." >&2
  echo "       Slice 18 regression: widget will not ship in the .app bundle." >&2
  exit 2
fi

if [[ ! -f "${PBXPROJ}" ]]; then
  echo "warning: pbxproj missing — run 'xcodegen generate' from ios/EpubToMp3/." >&2
  exit 0
fi

if ! grep -q '/\* EpubToMp3Widget \*/' "${PBXPROJ}"; then
  echo "error: pbxproj has no PBXTargetDependency on EpubToMp3Widget." >&2
  echo "       Re-run 'xcodegen generate' from ios/EpubToMp3/." >&2
  exit 2
fi

if ! grep -q 'EpubToMp3Widget.appex in Embed Foundation Extensions' "${PBXPROJ}"; then
  echo "error: pbxproj is missing the 'Embed Foundation Extensions' copy phase." >&2
  echo "       Slice 18 regression: widget will not be copied into PlugIns/." >&2
  exit 2
fi

echo "ok: iOS widget is wired into the app bundle (project.yml + pbxproj checks pass)."
