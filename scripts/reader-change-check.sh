#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 --cached | --commit <revision> | --paths <path>..." >&2
    exit 2
}

mode="${1:-}"
shift || true
changed_files=()
case "$mode" in
    --cached)
        while IFS= read -r path; do
            changed_files+=("$path")
        done < <(git diff --cached --name-only --diff-filter=ACMR)
        ;;
    --commit)
        [[ $# -eq 1 ]] || usage
        while IFS= read -r path; do
            changed_files+=("$path")
        done < <(git diff-tree --no-commit-id --name-only -r "$1")
        ;;
    --paths)
        [[ $# -gt 0 ]] || usage
        changed_files=("$@")
        ;;
    *) usage ;;
esac

reader_changed=0
native_test_changed=0
for path in "${changed_files[@]}"; do
    case "$path" in
        ios/EpubToMp3/EpubToMp3/Features/Reader/*|\
        ios/EpubToMp3/EpubToMp3/App/IOSRootContainer.swift|\
        ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift)
            reader_changed=1
            ;;
    esac
    case "$path" in
        ios/EpubToMp3/EpubToMp3Tests/*|ios/EpubToMp3/EpubToMp3UITests/*)
            native_test_changed=1
            ;;
    esac
done

if [[ "$reader_changed" -eq 1 && "$native_test_changed" -eq 0 ]]; then
    echo "Reader production changes require a native XCTest or UI-test change in the same commit." >&2
    echo "Use \$native-reader-regression and add the behavior-level regression test before committing." >&2
    exit 1
fi

if [[ "$reader_changed" -eq 1 ]]; then
    echo "Reader change paired with native test coverage."
fi
