#!/usr/bin/env bash
# Stop hook: check disk free; if pressure is high, append a hint to
# the systemMessage stream so Claude knows to run /agents disk-janitor
# in the next turn. We DON'T spawn the agent inline here — Stop hooks
# run synchronously and a multi-minute cleanup would stall the
# assistant. The hint is non-blocking; ignoring it is fine.
#
# Thresholds:
#   < 5 GB  → urgent (suggest agent immediately)
#   < 20 GB → notice
#   ≥ 20 GB → silent

set -euo pipefail

# df returns lines like:
#   /dev/disk1s4s1   233Gi    10Gi    15Gi    42%    427k  154M    0%   /
# We pull the Avail column (4th field). Strip the unit suffix and
# normalise to GB.
read_free_gb() {
  local raw
  raw=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "$raw" ]]; then
    echo "0"
    return
  fi
  # df -k is in 1024-byte blocks; convert to GiB.
  echo $((raw / 1024 / 1024))
}

FREE_GB=$(read_free_gb)
LOG="${HOME}/.local/share/disk-janitor.log"
mkdir -p "$(dirname "${LOG}")"

if (( FREE_GB < 5 )); then
  printf '%s  free=%dGB URGENT — recommend /agents disk-janitor now\n' \
    "$(date -u +%FT%TZ)" "$FREE_GB" >> "${LOG}"
  cat <<EOF
{"systemMessage": "🚨 Disco em ${FREE_GB} GB livres. Rode /agents disk-janitor pra liberar espaço."}
EOF
elif (( FREE_GB < 20 )); then
  printf '%s  free=%dGB notice\n' "$(date -u +%FT%TZ)" "$FREE_GB" >> "${LOG}"
  cat <<EOF
{"systemMessage": "⚠️ Disco em ${FREE_GB} GB livres. Considere /agents disk-janitor."}
EOF
fi
# Silent above 20 GB.
exit 0
