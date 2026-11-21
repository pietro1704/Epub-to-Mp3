#!/usr/bin/env bash
set -euo pipefail

sha=${VALIDATED_SHA:-}
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Expected a full release commit SHA from the validation gate." >&2
  exit 64
fi

# HEAD is the trusted master checkout from the previous workflow step.
# Check the local object and ancestry before changing the working tree.
if [[ "$(git rev-parse --verify "${sha}^{commit}" 2>/dev/null)" != "$sha" ]] ||
  ! git merge-base --is-ancestor "$sha" HEAD; then
  echo "::error::The validated release commit is absent from the trusted master history." >&2
  exit 65
fi

exec git switch --detach "$sha"
