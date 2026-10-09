#!/usr/bin/env bash
set -euo pipefail

SCOPE="all"
if [[ "$#" -gt 0 ]]; then
  if [[ "$#" -ne 2 || "$1" != "--scope" || "$2" != "device-workflow" ]]; then
    echo 'Usage: preflight.sh [--scope device-workflow]' >&2
    exit 2
  fi
  SCOPE="$2"
fi

echo '== repository preflight =='
git diff --check

if git diff --name-only --diff-filter=U | grep -q .; then
  echo 'Unresolved merge conflicts are present.' >&2
  exit 1
fi

branch=$(git branch --show-current)
if [[ -z "$branch" ]]; then
  branch="(detached HEAD)"
fi
integration=$(git config --get gitflow.branch.develop || echo develop)
if [[ "$branch" == master || "$branch" == main || "$branch" == "$integration" ]]; then
  echo "Run preflight from a feature or fix ref, not '$branch'." >&2
  exit 1
fi

baseline="$integration"
if git show-ref --verify --quiet "refs/remotes/origin/$integration"; then
  baseline="origin/$integration"
fi
if git rev-parse --verify "$baseline" >/dev/null 2>&1 \
  && ! git merge-base --is-ancestor "$baseline" HEAD; then
  echo "Branch '$branch' is behind $baseline; update it before verification." >&2
  exit 1
fi

echo "Branch: $branch"
if [[ "$SCOPE" == "device-workflow" ]]; then
  echo 'Focused host workflow checks; native evidence is verified separately by XCTest.'
  mise run ios:device:workflow:test
  echo '== device workflow preflight passed =='
  exit 0
fi
if [[ "${CI:-false}" != "true" ]]; then
  echo 'Full Python/lint gates run in CI. Select --scope device-workflow for native host verification.'
  exit 0
fi
echo 'Rust formatting...'
cargo fmt --all -- --check

# Verification must not install a legacy Apple runtime as a side effect.
# Explicit setup/build tasks own dependency installation and artifact generation.

echo 'Python, integration, and Web tests...'
mise run test

echo 'Rust workspace tests...'
cargo test --workspace

echo 'Web production build...'
(cd web && npm run build)

echo 'Repository hooks and native-reader pairing...'
mise run hooks-test

echo '== preflight passed =='
