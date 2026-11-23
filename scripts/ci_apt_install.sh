#!/usr/bin/env bash
# Install apt packages on a GitHub-hosted Ubuntu runner with a hard time limit.
#
#   ci_apt_install.sh [--install-recommends] PACKAGE...
#
# Packages that dpkg already reports as installed are skipped, and apt is not
# contacted when none is missing. Otherwise the Azure mirror is normalized, then
# update + install run up to CI_APT_ATTEMPTS (3) times, each bounded by
# CI_APT_ATTEMPT_TIMEOUT seconds (150), so one hung mirror request costs one
# attempt instead of the job. APT's signature validation is never weakened.
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
  timeout "$limit" bash -c '
    set -euo pipefail
    flag=$1; shift
    options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
    sudo apt-get "${options[@]}" -o APT::Update::Error-Mode=any update
    sudo apt-get "${options[@]}" install -y ${flag:+"$flag"} "$@"
  ' _ "${recommends[*]:-}" "${missing[@]}" || status=$?
  if (( status == 0 )); then
    exit 0
  fi
  echo "apt: attempt $n failed with status $status" >&2
  if (( n < attempts )); then sleep "${CI_APT_RETRY_DELAY:-5}"; fi
done
echo "::error::apt install failed after $attempts attempts: ${missing[*]}" >&2
exit 1
