#!/usr/bin/env bash
# Compatibility advisory only. Checkout-wide edits cannot prove task ownership
# or meaningful regression coverage. The canonical review owns acceptance.
set -euo pipefail
cat >/dev/null
if [[ "${EPUB_REVIEW_NOTICE:-0}" == "1" ]]; then
    printf '%s\n' 'test_coverage_gate: review owned changes against the approved task acceptance; unrelated test edits do not establish coverage. No automatic checks or Stop block.' >&2
fi
