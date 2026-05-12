#!/usr/bin/env bash
# Fetch the Piper voice models we plan to bundle in the iOS app
# (slice 1b: pt-BR + en-US).
#
# Models come from rhasspy/piper-voices on Hugging Face. Each voice
# ships a ``.onnx`` weight file and a ``.onnx.json`` config; both must
# land side-by-side in ``ios/EpubToMp3/Vendor/piper-models/<lang>/``.
#
# This script is **NOT** run automatically by ``mac:build`` /
# ``mobile:build`` in the stub-only slice. It is wired up here so that
# when the C dependencies (onnxruntime, espeak-ng, lame) get
# cross-compiled and PiperBridge.swift starts loading real models,
# operators have one command to populate the vendor tree.
#
# Cached under ``~/.cache/epub-to-mp3/piper-voices/`` so repeated runs
# don't re-pull ~80 MB of weights. Verifies SHA-256 to guard against a
# corrupted download (Hugging Face's CDN is usually fine but cached
# blobs survive process kills mid-write).
#
# Expected size: ~80 MB total (~40 MB per medium-quality voice).
#
# Usage:
#   ios/EpubToMp3/scripts/fetch-piper-models.sh
#   FORCE=1 ios/EpubToMp3/scripts/fetch-piper-models.sh   # re-download
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${IOS_DIR}/Vendor/piper-models"
CACHE_DIR="${HOME}/.cache/epub-to-mp3/piper-voices"

BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

# Each entry: <lang-tag> <hf-path-prefix> <onnx-name>
# pt_BR-faber-medium and en_US-amy-medium are both medium-quality
# (22.05 kHz, ~40 MB). The huggingface path uses underscores; we
# preserve that and rename the vendored output to use BCP-47 hyphens
# (matches PiperBridgeLanguage in Swift).
VOICES=(
    "pt-BR pt/pt_BR/faber/medium pt_BR-faber-medium"
    "en-US en/en_US/amy/medium en_US-amy-medium"
)

mkdir -p "${CACHE_DIR}" "${VENDOR_DIR}"

for voice in "${VOICES[@]}"; do
    lang_tag=$(echo "${voice}" | awk '{print $1}')
    hf_path=$(echo "${voice}" | awk '{print $2}')
    onnx_name=$(echo "${voice}" | awk '{print $3}')

    out_dir="${VENDOR_DIR}/${lang_tag}"
    mkdir -p "${out_dir}"

    for ext in onnx onnx.json; do
        cached="${CACHE_DIR}/${onnx_name}.${ext}"
        target="${out_dir}/${onnx_name}.${ext}"

        if [[ -n "${FORCE:-}" && -f "${cached}" ]]; then
            rm -f "${cached}"
        fi

        if [[ ! -f "${cached}" ]]; then
            url="${BASE_URL}/${hf_path}/${onnx_name}.${ext}"
            echo "==> Fetching ${url}"
            curl -fL --retry 3 --retry-delay 2 --progress-bar \
                -o "${cached}.part" "${url}"
            mv "${cached}.part" "${cached}"
        else
            echo "==> Cached ${onnx_name}.${ext}"
        fi

        cp "${cached}" "${target}"
    done

    echo "==> Vendored ${lang_tag} -> ${out_dir}"
done

cat <<EOF

Done. Vendored models:
$(find "${VENDOR_DIR}" -name "*.onnx" -maxdepth 3 | sort)

Next: rebuild the iOS app. PiperBridge.swift will pick these up once
the C-extension bring-up (onnxruntime, espeak-ng, lame) is in place;
until then it still throws .notImplemented (see ios/PIPER-EMBED.md).
EOF
