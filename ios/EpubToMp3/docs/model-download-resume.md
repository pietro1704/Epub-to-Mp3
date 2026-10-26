# Model download range recovery

Apple model downloads use the existing background URLSession adapter. Rust still
authorizes the pinned catalogue manifest, checks the complete artifact size and
SHA-256, stages verified artifacts and publishes the model atomically.

## Transport contract

- Request at most 4 MiB using `Range` and identity content encoding.
- A `206` must have the exact requested start, a bounded end, the manifest's full
  length, the exact response-body length and a strong ETag. Actual `206` behavior,
  rather than an `Accept-Ranges` advertisement, establishes range support.
- Persist completed ranges only. The next request carries the strong ETag in
  `If-Range`. Weak ETags and Last-Modified alone deliberately use a full download.
- Store a versioned receipt beside the partial file in Rust's owned download
  inbox. Bind it to the operation ID, model ID, model revision, artifact index,
  pinned source URL, expected size, destination and ETag.
- Synchronize the appended prefix before atomically writing its committed length.
  On restart, truncate an uncommitted tail of at most one block. Reject a shorter
  prefix, an oversized prefix, a stale identity or an invalid receipt.
- A `200` replaces the prefix with the full response, including when the server
  ignores Range or rejects If-Range. Never append a full response to saved bytes.
- Rust preflight reserves the pending artifact bytes, one additional largest
  pending artifact and the existing 16 MiB safety margin. The additional artifact
  covers a full `200` download temporarily coexisting with its committed prefix.
  Completed, verified staging artifacts are excluded from that pending reserve.
- Invalid `206` or `416` restarts once without a Range header. A further invalid
  response fails. Transient connection errors get at most two retries per
  artifact, retaining the last committed prefix. Exhaustion follows the existing
  Rust failure cleanup; explicit cancellation follows its cancellation cleanup.
- After the final range, move the reconstructed file to the original Rust inbox
  path. Rust hashes the entire file, including its saved prefix, before accepting
  it. A checkpoint, ETag or HTTP success never establishes installed integrity.

## Relaunch and cancellation

Each OS task description includes its literal model descriptor and range request.
Legacy task descriptions remain readable. Existing OS background tasks reconnect
through the current client. A dormant Rust operation starts its next request from
the transport checkpoint. Verified staging artifacts remain a separate recovery
mechanism; they are not downloaded again.

An interrupted in-flight range is downloaded again from its last committed
boundary. No opaque URLSession resumeData is persisted. Cancellation serializes
against prefix writes before Rust cleans its owned directories, and prevents the
next range from being enqueued for that operation.

Completed, failed and cancelled Rust operations reject late progress,
verification and publication. Repeated cancellation is harmless and never cleans
the staging or inbox of a subsequent attempt for the same model.

## Acceptance fixtures

`SpeechModelRangeDownloadTests` covers persisted-prefix recovery, interrupted
append/final rename, invalid validators and ranges, stale identities, bounded
retry, cancellation rejection, symlink isolation and byte/hash equality.

`SpeechModelRangeHTTPTests` is the bounded local-server proof. It drives the actual
transport through a test-only URLProtocol bridge to a loopback HTTP server:
interruption, changed validator, ignored Range, malformed Content-Range and a
fresh transport recovering persisted state. It does not establish real TLS,
iOS background-suspension acceptance. Cancellation holds the second range before
its response, verifies that an unrelated operation ID cannot cancel it, then
cancels the matching operation and checks that only its committed prefix remains.
`SpeechModelRangeCrashTests` kills only an
owned fixture writer after fsync and verifies recovery through a fresh transport
and the loopback server. This covers the persisted crash boundary, not forcibly
terminating the shipping app. Final validation must distinguish those cases.
No fixture downloads a public model.

Rust's `reconstructed_ranges_require_the_full_manifest_hash_including_the_saved_prefix`
checks acceptance of reconstructed bytes and rejection of a same-size corrupted
prefix while preserving the previous installed model.

The portable reqwest installer retains its current full-download behavior. This
change adds no provider abstraction and makes no claim about server support until
the corresponding acceptance run has completed.
