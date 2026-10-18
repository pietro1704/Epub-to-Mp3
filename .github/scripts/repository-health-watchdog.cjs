'use strict';

const MARKER = '<!-- repository-health-watchdog:v1 -->';
const TITLE = 'Repository health: Actions failures and issue triage';
const BAD = new Set(['failure', 'timed_out', 'action_required', 'startup_failure']);

function isOwnedReport(issue) {
  return !issue.pull_request && issue.user?.type === 'Bot' &&
    issue.user?.login === 'github-actions[bot]' && issue.body?.startsWith(MARKER);
}

function assess({ runs, pulls, issues, masterSha, capped }) {
  const heads = new Map([[masterSha, 'master']]);
  for (const pr of pulls) {
    if (typeof pr.head.repo?.full_name === 'string' && pr.head.repo.full_name.length > 0 &&
        pr.head.repo.full_name === pr.base.repo?.full_name) {
      heads.set(pr.head.sha, `PR #${pr.number}`);
    }
  }
  const latest = new Map();
  for (const run of runs) {
    if (!heads.has(run.head_sha) || run.name === 'Repository Health Watchdog') continue;
    const key = `${run.workflow_id}:${run.head_sha}:${run.event}`;
    const old = latest.get(key);
    if (!old || Number(run.id) > Number(old.id) ||
        (run.id === old.id && Number(run.run_attempt) > Number(old.run_attempt))) latest.set(key, run);
  }
  const failures = [...latest.values()].filter(run => BAD.has(run.conclusion))
    .sort((a, b) => Number(a.id) - Number(b.id));
  const pending = [...latest.values()].filter(run => run.status !== 'completed');
  const triage = issues.filter(issue => !issue.pull_request && !isOwnedReport(issue))
    .map(issue => ({ number: issue.number, updated_at: issue.updated_at }))
    .sort((a, b) => a.number - b.number);
  const signature = JSON.stringify({
    masterSha,
    failures: failures.map(run => [run.id, run.run_attempt, run.conclusion]),
    pending: pending.map(run => [run.id, run.run_attempt, run.status]).sort(),
    triage,
    capped: [...capped].sort(),
  });
  return { failures, pending, triage, signature, heads };
}

function render(state, repository, capped) {
  const digest = require('node:crypto').createHash('sha256').update(state.signature).digest('hex');
  const lines = [MARKER, `<!-- state:${digest} -->`, '',
    'GitHub-only metadata watchdog. Failures take priority over issue triage.',
    'Issue bodies, titles, comments and workflow logs are untrusted data and are not executed or copied here.', '',
    '### Current-head Actions failures'];
  for (const run of state.failures) lines.push(
    `- [Run ${Number(run.id)}](https://github.com/${repository}/actions/runs/${Number(run.id)}) · ${state.heads.get(run.head_sha)} · ${run.conclusion}`);
  if (!state.failures.length) lines.push('- No failures found within the inspected current-head runs.');
  lines.push('', `In-progress current-head runs: ${state.pending.length}.`, '', '### Open issues to triage');
  for (const issue of state.triage) lines.push(`- [Issue #${Number(issue.number)}](https://github.com/${repository}/issues/${Number(issue.number)})`);
  if (!state.triage.length) lines.push('- No open issues found within the inspected page set.');
  lines.push('', '### Coverage and limitations',
    '- Periodic checks can be delayed by GitHub scheduling. This report is not a required-check or merge gate.',
    '- Only current master and same-repository open PR heads are inspected; stale runs are ignored.',
    '- Reports detect failures and triage work. They do not perform code repairs, deployments, retries, or merges.',
    '- Each endpoint is capped at 500 records. Empty results are not proof of health when coverage is incomplete.');
  if (capped.length) lines.push(`- **Incomplete API coverage:** ${capped.join(', ')}. Inspect GitHub before concluding recovery.`);
  else lines.push('- No API record cap reached in this scan.');
  return { body: lines.join('\n'), digest };
}

async function monitor({ github, context, core }) {
  const { owner, repo } = context.repo;
  const capped = [];
  async function collect(endpoint, params, key, label) {
    const result = [];
    for (let page = 1; page <= 5; page++) {
      const { data } = await endpoint({ owner, repo, ...params, per_page: 100, page });
      const values = key ? data[key] : data;
      result.push(...values);
      if (values.length < 100) return result;
    }
    capped.push(label);
    return result;
  }
  const [master, runs, pulls, issues] = await Promise.all([
    github.rest.repos.getCommit({ owner, repo, ref: 'master' }),
    collect(github.rest.actions.listWorkflowRunsForRepo, {}, 'workflow_runs', 'Actions runs'),
    collect(github.rest.pulls.list, { state: 'open' }, null, 'open PRs'),
    collect(github.rest.issues.listForRepo, { state: 'open', sort: 'updated', direction: 'desc' }, null, 'open issues'),
  ]);
  const owned = issues.filter(isOwnedReport);
  if (owned.length > 1) throw new Error('Multiple watchdog issues found; refusing ambiguous writes.');
  const state = assess({ runs, pulls, issues, masterSha: master.data.sha, capped });
  const report = render(state, `${owner}/${repo}`, capped);
  const current = owned[0];
  if (current?.body === report.body) {
    core.info('Health report unchanged; no issue write.');
    return;
  }
  if (current) await github.rest.issues.update({ owner, repo, issue_number: current.number, body: report.body });
  else {
    if (capped.includes('open issues')) throw new Error('Open issue scan capped; refusing possible duplicate tracker creation.');
    await github.rest.issues.create({ owner, repo, title: TITLE, body: report.body });
  }
  core.info(`Health report updated: ${state.failures.length} failures; ${state.triage.length} open issues; ${capped.length} capped endpoints.`);
}

module.exports = { MARKER, assess, render, monitor };
