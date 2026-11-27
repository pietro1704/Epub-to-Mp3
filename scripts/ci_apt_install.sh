#!/usr/bin/env bash
# Install apt packages on a GitHub-hosted Ubuntu runner with a hard time limit.
#
#   ci_apt_install.sh [--install-recommends] PACKAGE...
#
# Packages that dpkg already reports as installed are skipped, and apt is not
# contacted when none is missing. Otherwise the Azure mirror is normalized, then
# update + install run up to CI_APT_ATTEMPTS (3) times, each bounded by
# CI_APT_ATTEMPT_TIMEOUT seconds (150), so one hung mirror request costs one
# attempt instead of the job. A timed-out attempt also kills the orphaned apt process that
# would keep the dpkg lock, and apt waits up to CI_APT_LOCK_TIMEOUT (120) for the lock. APT's signature validation is never weakened.
#
# CI_APT_ARCHIVES=<dir> (opt-in) points apt's package archive at a directory that
# a workflow persists with actions/cache: .deb files already there are reused and
# partial downloads survive between attempts. Unset keeps apt's default cache.
set -euo pipefail

recommends=(--no-install-recommends)
if [[ "${1:-}" == '--install-recommends' ]]; then
  recommends=()
  shift
fi
(( $# > 0 )) || { echo 'usage: ci_apt_install.sh [--install-recommends] PACKAGE...' >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attempts="${CI_APT_ATTEMPTS:-3}"
limit="${CI_APT_ATTEMPT_TIMEOUT:-150}"
kill_after="${CI_APT_KILL_AFTER:-10}"
lock_wait="${CI_APT_LOCK_TIMEOUT:-120}"

if [[ -n "${CI_APT_ARCHIVES:-}" ]]; then
  mkdir -p "$CI_APT_ARCHIVES/partial"
  # The runner user owns the tree so actions/cache can restore and save it; apt's
  # sandbox user must be able to write partial downloads.
  chmod 0755 "$CI_APT_ARCHIVES"
  chmod 0777 "$CI_APT_ARCHIVES/partial"
  export CI_APT_ARCHIVES
  # apt runs as root, so hand the tree back to the runner user on exit; otherwise
  # actions/cache cannot read root-owned partial/ and lock entries when saving.
  trap 'sudo chown -R "$(id -u):$(id -g)" "$CI_APT_ARCHIVES" 2>/dev/null || true' EXIT
fi

missing=()
for package in "$@"; do
  dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
done
if (( ${#missing[@]} == 0 )); then
  echo "apt: already installed: $*"
  exit 0
fi

ruby_bin="$(command -v /usr/bin/ruby || command -v ruby)"
sudo "$ruby_bin" "$root/scripts/normalize_ubuntu_package_mirror.rb"

for (( n = 1; n <= attempts; n++ )); do
  echo "apt: attempt $n/$attempts (limit ${limit}s): ${missing[*]}"
  status=0
  timeout --kill-after="$kill_after" "$limit" bash -c '
    set -euo pipefail
    flag=$1; lock_wait=$2; shift 2
    options=(-o "DPkg::Lock::Timeout=$lock_wait" -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
    if [[ -n "${CI_APT_ARCHIVES:-}" ]]; then
      options+=(-o "Dir::Cache::Archives=$CI_APT_ARCHIVES" -o APT::Keep-Downloaded-Packages=true)
      # The runner workspace is not traversable by the _apt user, which only
      # produced an unsandboxed warning; download as root explicitly. Signature
      # validation of the downloaded packages is unchanged.
      options+=(-o APT::Sandbox::User=root)
    fi
    sudo apt-get "${options[@]}" -o APT::Update::Error-Mode=any update
    sudo apt-get "${options[@]}" install -y ${flag:+"$flag"} "$@"
  ' _ "${recommends[*]:-}" "$lock_wait" "${missing[@]}" || status=$?
  if (( status == 0 )); then
    exit 0
  fi
  echo "apt: attempt $n failed with status $status" >&2
  if (( status == 124 || status == 137 )); then
    # timeout kills the bash wrapper, but a root apt-get child can outlive it and keep
    # the dpkg lock, failing every later attempt at once. Stop it before retrying.
    sudo pkill -KILL -x apt-get 2>/dev/null || true
  fi
  if (( n < attempts )); then sleep "${CI_APT_RETRY_DELAY:-5}"; fi
done
echo "::error::apt install failed after $attempts attempts: ${missing[*]}" >&2
exit 1
