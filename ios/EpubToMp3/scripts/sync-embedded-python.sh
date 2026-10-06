#!/usr/bin/env bash
# Sync the pure-Python modules embedded as app resources with the canonical
# repository sources. This deliberately does not create or download a Python
# runtime; bootstrap-ios-python.sh remains responsible for that expensive work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYAPP_SOURCE="$(cd "${IOS_DIR}/../.." && pwd)/python_app"
SITE_PACKAGES="${IOS_DIR}/Vendor/site-packages"
PYAPP_DESTINATION="${SITE_PACKAGES}/python_app"

if [[ ! -d "${PYAPP_SOURCE}/src" ]]; then
  echo "error: canonical python_app/src is missing at ${PYAPP_SOURCE}" >&2
  exit 1
fi

mkdir -p "${SITE_PACKAGES}"
LOCK_DIRECTORY="${SITE_PACKAGES}/.python-app-sync.lock"
for attempt in {1..300}; do
  if mkdir "${LOCK_DIRECTORY}" 2>/dev/null; then
    trap 'rmdir "${LOCK_DIRECTORY}"' EXIT
    break
  fi
  sleep 0.1
done
if [[ ! -d "${LOCK_DIRECTORY}" ]]; then
  echo "error: timed out waiting to synchronize embedded python_app sources" >&2
  exit 1
fi

SOURCE_SIGNATURE="$(
  find "${PYAPP_SOURCE}" -type f ! -path '*/__pycache__/*' -exec shasum {} + \
    | shasum \
    | awk '{print $1}'
)"
SIGNATURE_FILE="${SITE_PACKAGES}/.python-app-source-signature"
if [[ -d "${PYAPP_DESTINATION}" ]] \
  && [[ -f "${SIGNATURE_FILE}" ]] \
  && [[ "$(<"${SIGNATURE_FILE}")" == "${SOURCE_SIGNATURE}" ]]; then
  echo "==> Embedded python_app sources already match the repository"
  exit 0
fi

rm -rf "${PYAPP_DESTINATION}"
mkdir -p "${PYAPP_DESTINATION}"

cp "${PYAPP_SOURCE}/__init__.py" "${PYAPP_DESTINATION}/"
cp "${PYAPP_SOURCE}/version.py" "${PYAPP_DESTINATION}/"
cp -R "${PYAPP_SOURCE}/src" "${PYAPP_DESTINATION}/src"
find "${PYAPP_DESTINATION}" -type d -name "__pycache__" -exec rm -rf {} +
printf '%s\n' "${SOURCE_SIGNATURE}" > "${SIGNATURE_FILE}"

echo "==> Synced embedded python_app sources"
