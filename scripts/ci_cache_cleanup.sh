#!/usr/bin/env bash
# Delete GitHub Actions caches that can no longer be restored by anything useful:
# caches of closed/merged pull requests, of deleted branches and obsolete key families.
# master caches are never touched. Needs only bash and gh (repo from GH_REPO or git remote).
# Usage: ci_cache_cleanup.sh [--dry-run] [--pr <number>]
set -uo pipefail
dry=0; only_pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --pr) only_pr="${2:?--pr needs a number}"; shift ;;
    *) echo "usage: $0 [--dry-run] [--pr <number>]" >&2; exit 2 ;;
  esac
  shift
done
repo="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}" || exit 2

freed=0; deleted=0
# id, ref, size, key
while IFS=$'\t' read -r id ref size key; do
  reason=""
  case "$ref" in
    refs/heads/master) continue ;;
    refs/pull/*/merge)
      n="${ref#refs/pull/}"; n="${n%/merge}"
      [ -z "$only_pr" ] || [ "$only_pr" = "$n" ] || continue
      state="$(gh api "repos/$repo/pulls/$n" --jq .state 2>/dev/null || echo unknown)"
      [ "$state" = closed ] && reason="PR #$n is closed" ;;
    refs/heads/*)
      [ -z "$only_pr" ] || continue
      branch="${ref#refs/heads/}"
      gh api "repos/$repo/branches/$branch" >/dev/null 2>&1 || reason="branch $branch no longer exists" ;;
  esac
  case "$key" in xcode-compile-cache-v1-*) reason="${reason:-obsolete key family}" ;; esac
  [ -n "$reason" ] || continue
  echo "$([ $dry = 1 ] && echo would-delete || echo delete) $((size / 1048576)) MiB  $key  ($reason)"
  if [ $dry = 0 ]; then gh api -X DELETE "repos/$repo/actions/caches/$id" >/dev/null || continue; fi
  freed=$((freed + size)); deleted=$((deleted + 1))
done < <(gh api --paginate "repos/$repo/actions/caches?per_page=100" --jq '.actions_caches[] | [.id, .ref, .size_in_bytes, .key] | @tsv')

total="$(gh api "repos/$repo/actions/cache/usage" --jq .active_caches_size_in_bytes)"
echo "Caches matched/removed (dry run=$dry): $deleted, $((freed / 1048576)) MiB. Repository cache usage before this report: $((total / 1048576)) MiB of 10240 MiB."
