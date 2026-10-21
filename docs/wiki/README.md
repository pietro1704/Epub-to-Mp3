# Project wiki sources

Versioned local pages are available in [English](en/Home.md) and
[Português do Brasil](pt-BR/Home.md). Preserve each language intentionally and
update both when product facts change. Pages describe source ownership and
capability limits; they do not certify deployment, release or runtime success.

Local edits are reviewed in the same scoped PR as the relevant change.
[AGENTS.md](../../AGENTS.md) and
[execution policy](../agents/execution-policy.md) remain canonical for development
and delivery. Wiki prose is not an additional agent permission source.

GitHub Wiki publication is a separate external action. Inspect the current
`scripts/github-ci-wiki-wizard.sh` before any explicitly authorized publication;
do not run it merely to validate Markdown or update local pages. Its other
workflow/commit actions must fit the authorized scope. TestFlight publication
likewise requires its own task and actual signing/account prerequisites.

Recommended reading order: Home, Getting Started, CLI and Web, Desktop/Mobile,
Architecture, Configuration, Deployment, Troubleshooting, Contribution/Security.
