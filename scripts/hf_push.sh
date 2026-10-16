#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: hf_push.sh SNAPSHOT REMOTE_URL' >&2
  exit 64
fi
cd "$1"
# The LFS pre-push hook must run; never set a hooksPath override here.
git remote add hf "$2"
git push --force hf HEAD:refs/heads/master
git push --force hf HEAD:refs/heads/main
echo 'HF snapshot push completed successfully.'
