#!/usr/bin/env bash
set -euo pipefail

checker="./scripts/reader-change-check.sh"

"$checker" --paths docs/adr/example.md

if "$checker" --paths ios/EpubToMp3/EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift; then
    echo "Expected an unpaired native reader production change to fail." >&2
    exit 1
fi

"$checker" --paths \
    ios/EpubToMp3/EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift \
    ios/EpubToMp3/EpubToMp3UITests/ReaderModesUITests.swift
