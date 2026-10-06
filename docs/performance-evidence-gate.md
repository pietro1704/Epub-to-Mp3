# Cross-client performance evidence gate

## Current capability and missing release evidence

The command imports **original Apple diagnostic JSON**, checks artifact hashes
and referenced journey identities, and reports comparable observation cohorts.
It is not yet the automated cross-client collection gate required by #575.
It never reports a release as passed. A completed, in-budget observation cohort
has `observations_status: passed` but release `status: pending` until all
`pending_requirements` have executable evidence adapters.

Still required: automated cold/relaunch lifecycle capture, representative corpus
verification (including sideways two-up scan geometry), backend streaming
correlation, actual CLI/server output-integrity evidence, and web/Flutter profile
collectors. Merely adding flags or hashes cannot satisfy those requirements.
Hashes establish byte identity, not the truth of runner or lifecycle claims.
The report labels this input `imported_diagnostics_not_verified_collection`.

The earlier schema-1 summaries and `conversion_integrity: {cli: true, server:
true}` are deliberately rejected. Repeated hand-entered milliseconds and boolean
assertions are not representative evidence, even when their percentiles look good.

## Import an Apple diagnostic capture

Explicitly export diagnostics from the Apple app. Preserve the original JSON
array, whose entries contain `id`, `kind`, `context`, and `records`. The importer
reads those records; it does not read Swift source or accept `boundaries_ms`.
Keep artifacts outside the repository in a local collection directory:

```text
collection/
  evidence.json
  artifacts/
    <sha256-of-original-export-bytes>.json
```

Create a schema-2 manifest referencing the selected open, playback, and seek
UUIDs. Use fresh capture/run identifiers for each actual process launch; never
rename or duplicate a journey to increase the sample count. The metadata is an
operator-supplied collection annotation, not an automatically verified claim.
Do not include titles, book text, URLs, account IDs, device serials, or audio.
`runner` is a bounded technical model label, not the device's personal name.

```json
{
  "schema_version": 2,
  "captures": [
    {
      "client": "apple",
      "runner": "iPhone 16e",
      "execution_environment": "physical_device",
      "revision": "<40-hex-source-commit>",
      "run_id": "<process-launch-UUID>",
      "source_sha256": "<64-hex-export-digest>",
      "journeys": {
        "open": "<open-journey-UUID>",
        "play": "<playback-journey-UUID>",
        "seek": "<seek-journey-UUID>"
      },
      "corpus": {
        "kind": "epub",
        "sha256": "<64-hex-original-document-digest>",
        "size_bytes": 123456,
        "page_count": 420
      },
      "cache_state": "cold",
      "resource_policy": "normal"
    }
  ]
}
```

`physical_device` and `apple_ci` are the only accepted Apple environments;
the local iOS simulator remains prohibited. Corpus kinds: `epub`,
`selectable_text_pdf`, `sideways_two_up_scanned_pdf`. PDF page count is required.
Resource policies: `normal`, `reading_priority`, `playback_priority`,
`resource_constrained`.

A cold open must carry `cacheClass: cold`. A relaunch-warm annotation requires
`prepared_disk`; `in_memory_warm` is rejected. Prepared-disk reuse alone still
does not prove relaunch; collection lifecycle evidence remains pending.
Selected cancelled or incomplete journeys are rejected, never converted to zero
latency. Unrelated cancelled journeys in the same export can remain in the file.

## Run and interpret

```bash
mise run benchmark:journeys /path/to/collection/evidence.json --strict \
  --output /path/to/collection/report.json
```

The default matrix requests 20 cold and 20 relaunch-warm captures for every
client/corpus combination. Empty selections and fewer than 20 repetitions are
rejected. `--clients`, `--corpora`, and `--cache-states` can narrow diagnostic
inspection, never promote a partial matrix to release approval. Do not populate
web or Flutter captures with synthetic timings; their collectors are missing.

Cohorts retain corpus digest/size/pages, revision, runner, environment, cache,
resource policy, run IDs and source hashes. Different conditions are never pooled
to reach 20 samples. A reused journey/run or inconsistent metadata for one corpus
digest is rejected. p50/p95 are reported for each observed boundary, including
queue, audible playback and seek. `reader_usable` is the maximum of first readable
content and usable controls; PDFs also require their first page.

After 20 comparable observations, the 200 ms warm / 1000 ms cold p95 budget is
checked separately for reader usability and audible playback. A miss reports
`failed` even when other evidence is missing. The optimization queue identifies
the exact boundary and cohort; it does not invent missing server timings.

Exit codes: 2 for invalid input, 1 for a measured budget failure, and 0 for a
valid diagnostic import without `--strict`. Strict mode also returns 1 for pending
release evidence. Unit fixtures exercise this importer only; they are not product
benchmarks and must never be submitted as collected performance results.
