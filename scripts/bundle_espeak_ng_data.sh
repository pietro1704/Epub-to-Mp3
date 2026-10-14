#!/usr/bin/env bash
set -euo pipefail

# The active Apple provider policy is Edge plus system speech. Piper resources
# are bundled only for an explicitly requested optional runtime build.
[[ "${CONVERTER_FFI_ENABLE_PIPER:-0}" == 1 ]] || exit 0

root="$(cd "$(dirname "$0")/.." && pwd)"
data_root="$root/target/espeak-data"
if [[ ! -d "$data_root" ]]; then
  echo "error: eSpeak NG host data is absent; run the Simulator FFI build with all Simulators shut down" >&2
  exit 1
fi

source="$(find "$data_root" -path '*/out/build/espeak-ng-data/phontab' -type f -print -quit | sed 's#/phontab$##')"
if [[ -z "$source" || ! -f "$source/phondata" ]]; then
  echo "error: host build did not produce complete eSpeak NG runtime data" >&2
  exit 1
fi
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/espeak-ng-data"
mkdir -p "$destination"
ditto "$source" "$destination"
