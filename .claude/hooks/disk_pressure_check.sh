#!/usr/bin/env bash
# Read-only storage advisory. The native build guard owns build eligibility.
# Never persist a global log, dispatch an agent or authorize cleanup from Stop.
set -euo pipefail
cat >/dev/null
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
MINIMUM_GIB=$(jq -r '.minimum_free_gib // empty' "$PROJECT_DIR/config/mac-build-budget.json" 2>/dev/null || true)
[[ "$MINIMUM_GIB" =~ ^[0-9]+$ ]] || exit 0
FREE_KIB=$(df -Pk "$PROJECT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || exit 0
FREE_GIB=$((FREE_KIB / 1024 / 1024))
if (( FREE_GIB < MINIMUM_GIB )); then
    printf 'Storage notice: %s GiB free, configured minimum %s GiB. The canonical native guard determines build eligibility; cleanup requires its own authorized scope.\n' "$FREE_GIB" "$MINIMUM_GIB" >&2
fi
