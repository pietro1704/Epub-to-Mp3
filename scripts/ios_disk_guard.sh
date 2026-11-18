#!/bin/bash
# Compatibility entrypoint: check the shared native budget without evicting caches.
# Explicit cleanup belongs to the leased mac_build_budget.rb prune command.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${IOS_DERIVED_DATA_PATH:-${APPLE_DERIVED_DATA_PATH:-$REPO_ROOT/ios/EpubToMp3/.build}}"
exec mise -C "$REPO_ROOT" exec -- ruby "$REPO_ROOT/scripts/mac_build_budget.rb" check "$output_dir"
