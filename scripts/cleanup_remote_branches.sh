#!/usr/bin/env bash
set -euo pipefail

remote="origin"
apply=0
delete_dependabot=0

usage() {
  cat <<'EOF'
Usage: cleanup_remote_branches.sh [--remote NAME] [--apply] [--delete-dependabot]

Preview is the default. Deletion requires --apply. master, ios/*, mac/*,
and dependabot/* are preserved unless --delete-dependabot is explicit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) remote="${2:?missing remote name}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --delete-dependabot) delete_dependabot=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mapfile -t branches < <(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/${remote}"/heads/ | sort)
for branch in "${branches[@]}"; do
  [[ "$branch" == "HEAD" || "$branch" == "master" ]] && continue
  [[ "$branch" == ios/* || "$branch" == mac/* ]] && continue
  if [[ "$branch" == dependabot/* && "$delete_dependabot" -eq 0 ]]; then
    echo "PRESERVE $remote/$branch (Dependabot; use --delete-dependabot explicitly)"
    continue
  fi
  if [[ "$apply" -eq 1 ]]; then
    git push "$remote" --delete "$branch"
  else
    echo "DELETE  $remote/$branch (preview; rerun with --apply)"
  fi
done
