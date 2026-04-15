#!/usr/bin/env bash
# Stop hook: blocks Claude from stopping if code files were modified
# without corresponding test changes. Enforces rule: every code modification
# must ship with tests ("add tests for every modification").

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

# Consume stdin (Stop hook payload, not needed here)
cat >/dev/null

# List all modified files: staged + unstaged + untracked
MODIFIED=$( { git diff --name-only HEAD 2>/dev/null || true; \
              git ls-files --others --exclude-standard 2>/dev/null || true; } \
            | sort -u | grep -v '^$' || true)

[[ -z "$MODIFIED" ]] && exit 0

code_files=()
test_files_changed=0

while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    # Test files
    if [[ "$f" == python_app/tests/* ]] || \
       [[ "$f" == *.test.ts ]] || [[ "$f" == *.test.tsx ]] || \
       [[ "$f" == web/src/test/* ]]; then
        test_files_changed=1
        continue
    fi

    # Python source code (excludes tests, __init__, __main__)
    if [[ "$f" =~ ^python_app/.*\.py$ ]] && [[ "$f" != python_app/tests/* ]]; then
        base="$(basename "$f")"
        if [[ "$base" != "__init__.py" ]] && [[ "$base" != "__main__.py" ]]; then
            code_files+=("$f")
            continue
        fi
    fi

    # TypeScript / React source (excludes tests, .d.ts)
    if [[ "$f" =~ ^web/src/.*\.(ts|tsx)$ ]] && \
       [[ "$f" != *.test.ts ]] && [[ "$f" != *.test.tsx ]] && \
       [[ "$f" != web/src/test/* ]] && [[ "$f" != *.d.ts ]]; then
        code_files+=("$f")
        continue
    fi
done <<< "$MODIFIED"

# Code modified without test changes → block
if [[ ${#code_files[@]} -gt 0 && $test_files_changed -eq 0 ]]; then
    files_joined=$(printf '  - %s\n' "${code_files[@]}" | head -20)
    reason="Code files modified without test changes. Project rule: every code modification must ship with tests.

Modified code (no matching test changes):
$files_joined

Add or update tests in python_app/tests/ or web/src/**/*.test.{ts,tsx}, then run 'mise run test' before stopping. If tests are genuinely not applicable (e.g. comment-only edit, pure formatting), justify explicitly."

    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
fi

exit 0
