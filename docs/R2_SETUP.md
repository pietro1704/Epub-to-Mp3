# Optional Cloudflare R2 integration reference

R2 is optional external object storage. This repository does not establish an
active bucket, credentials, public URL, retention policy, scheduled cleanup or
working upload path. The earlier R2 recipe described a legacy integration and
must not be used as proof of current deployment behavior.

Before proposing setup, inspect the exact deployed revision and its storage
adapter. The current Rust server/container path must explicitly consume the
chosen configuration; setting historical `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME` and `R2_PUBLIC_URL` variables alone does
not implement an integration. The legacy Python `/api/cleanup` endpoint removes
local output directories; it does not establish R2 TTL or a hosted cron job.

If R2 setup is explicitly requested, prepare the adapter/configuration change
and an evidence-backed deployment plan first. Account creation, bucket creation,
secret updates, public access, custom domains, scheduled deletion and service
restarts are separate external actions requiring task authorization. Keep tokens
scoped to the chosen bucket and necessary operations, use an appropriate expiry,
and store credentials in the deployment secret manager. Never commit or expose
secret values in logs or documentation.

Use the provider's current documentation to verify permissions, API endpoint,
public/private delivery, pricing, quotas and retention; no free-tier, permanent
storage, CDN, unlimited-download or fixed reboot-time promise is made here.
Public access should follow the intended access model, not be enabled by default.

An authorized integration needs a bounded upload/read-back test against the exact
revision, observed artifact identity, failure behavior, access controls and
cleanup policy. Report which external operations were performed and which remain
pending. Do not schedule destructive cleanup or reboot a Space as an inferred
troubleshooting step.

- [Cloudflare R2 documentation](https://developers.cloudflare.com/r2/)
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [Execution policy](agents/execution-policy.md)
