# Cross-client performance evidence gate

`scripts/performance_evidence_gate.py` summarizes recorded listener-visible
journeys. It deliberately does not generate timings, synthesize a device
result, or turn a unit test into product evidence.

The input is a JSON bundle with `schema_version: 1`. Every sample contains
only a corpus digest and bounded technical metadata; do not add titles, text,
URLs, account IDs, audio bytes, or local paths.

```json
{
  "schema_version": 1,
  "conversion_integrity": { "cli": true, "server": true },
  "samples": [
    {
      "client": "apple",
      "runner": "iPhone 16e",
      "execution_environment": "physical_device",
      "corpus": {
        "kind": "epub",
        "sha256": "<64 lowercase hex characters>",
        "size_bytes": 123456,
        "page_count": 420
      },
      "cache_state": "cold",
      "resource_policy": "normal",
      "boundaries_ms": {
        "reader_usable": 430.2,
        "audio_audible": 812.7,
        "seek_target_reached": 71.4
      }
    }
  ]
}
```

Supported clients are `apple`, `web`, and `flutter`. Apple samples must declare
`physical_device` or `apple_ci`; a simulator is rejected. The corpus kinds are
`epub`, `selectable_text_pdf`, and `sideways_two_up_scanned_pdf`. The normal
release matrix requires 20 `cold` and 20 `relaunch_warm` samples for every
client/corpus bucket and successful CLI plus server integrity checks.

```bash
mise run benchmark:journeys /tmp/journey-evidence.json --strict \
  --output /tmp/journey-evidence-report.json
```

The report is `pending` when evidence is absent, `failed` when a completed
bucket misses the 200 ms warm or one-second cold p95 budget (or an integrity
check failed), and `passed` only when the complete matrix is present and within
budget. `--strict` returns nonzero for both `pending` and `failed`; this is the
mode for release review. A missed budget produces an `optimization_queue` with
the affected client, corpus, cache state, p95, and budget.

Keep raw Apple diagnostic exports and browser/Flutter profile artifacts next to
the release evidence outside the repository. The JSON bundle is the redacted,
reviewable summary, not a replacement for those source artifacts.
