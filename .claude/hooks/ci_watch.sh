#!/usr/bin/env bash
# Retired automatic watcher, kept as a non-executing compatibility entrypoint.
# CI monitoring is opt-in and needs immutable repository/ref/SHA identity through
# the canonical delivery workflow; a push event alone grants no such authority.
set -euo pipefail
cat >/dev/null
printf '%s\n' 'ci_watch: automatic monitoring is disabled; follow the current project delivery policy for an explicitly requested audit.' >&2
