"""Print recent perf/error/freeze events from .logs/events.jsonl.

Usage: python scripts/print_events.py <events_file> [<limit>]
"""

from __future__ import annotations

import json
import sys
from collections import Counter


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: print_events.py <events_file> [<limit>]")
        return 2
    path = sys.argv[1]
    try:
        limit = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    except ValueError:
        limit = 30

    records = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        print(f"(no events log at {path})")
        return 0

    if not records:
        print("(empty events log)")
        return 0

    kinds = Counter(r.get("kind", "?") for r in records)
    print(f"events.jsonl - {len(records)} total")
    for kind, n in kinds.most_common():
        print(f"   {kind:>14}: {n}")

    freezes = [r for r in records if r.get("kind") == "freeze"]
    if freezes:
        print(f"\nfreezes ({len(freezes)}):")
        for r in freezes[-10:]:
            ts = r.get("timestamp", "")
            src = r.get("source", "")
            ch = r.get("chapter_index", 0)
            stalled = r.get("stalled_seconds", 0)
            action = r.get("action", "")
            print(f"   {ts} src={src} ch={ch} stalled={stalled}s action={action}")

    errors = [r for r in records if r.get("kind") == "chapter_error"]
    if errors:
        print(f"\nchapter errors ({len(errors)}):")
        for r in errors[-10:]:
            ch = r.get("chapter_index", 0)
            engine = r.get("engine", "")
            err = r.get("error", "")[:120]
            print(f"   ch={ch} engine={engine} err={err}")

    perfs = [r for r in records if r.get("kind") == "chapter_perf"]
    if perfs:
        cps_values = [r.get("chars_per_second", 0) for r in perfs if r.get("chars_per_second")]
        if cps_values:
            avg = sum(cps_values) / len(cps_values)
            print(f"\navg throughput: {avg:.1f} chars/s ({len(cps_values)} chapters)")
        n_show = min(limit, len(perfs))
        print(f"\nlast {n_show} chapter perf:")
        for r in perfs[-limit:]:
            ch = r.get("chapter_index", 0)
            engine = r.get("engine", "") or ""
            elapsed = r.get("elapsed_seconds", 0) or 0
            chars = r.get("char_count", 0) or 0
            cps = r.get("chars_per_second", 0) or 0
            name = (r.get("chapter_name", "") or "")[:50]
            print(
                f"   ch={ch:>3} engine={engine:<8} {elapsed:>6.1f}s  "
                f"{chars:>6} chars  {cps:>6.1f} c/s  {name}"
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
