#!/usr/bin/env bash
set -euo pipefail

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
if [[ "$branch" == master || "$branch" == main ]] \
  || git diff --quiet "origin/master" HEAD 2>/dev/null; then
  echo "Run preflight from a feature or fix ref, not '$branch'." >&2
  exit 1
fi

if git show-ref --verify --quiet refs/remotes/origin/master \
  && ! git merge-base --is-ancestor origin/master HEAD; then
  echo "Branch '$branch' is behind origin/master; update it before verification." >&2
  exit 1
fi

echo "Branch: $branch"
echo 'Rust formatting...'
cargo fmt --all -- --check

echo 'Python, integration, and Web tests...'
mise run test

echo 'Rust workspace tests...'
cargo test --workspace

echo 'Web production build...'
(cd web && npm run build)

echo 'Repository hooks and native-reader pairing...'
mise run hooks-test

echo '== preflight passed =='
