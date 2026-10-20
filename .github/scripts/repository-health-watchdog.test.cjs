'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { spawnSync } = require('node:child_process');
const { assess, render, monitor, MARKER } = require('./repository-health-watchdog.cjs');
const base = { runs: [], pulls: [], issues: [], masterSha: 'current', capped: [] };
const run = overrides => ({ id: 1, workflow_id: 2, event: 'push', head_sha: 'current', status: 'completed', conclusion: 'failure', run_attempt: 1, ...overrides });

function workflow(name) {
  const source = readFileSync(resolve(__dirname, '../workflows', name), 'utf8');
  const parsed = spawnSync('ruby', ['-rjson', '-ryaml', '-e',
    'puts JSON.generate(YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false))'],
  { input: source, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  return JSON.parse(parsed.stdout);
}

test('PR regression cannot schedule the privileged metadata monitor or skipped monitor check', () => {
  const regression = workflow('repository-health-watchdog-regression.yml');
  const events = regression.on ?? regression.true;
  assert.deepEqual(Object.keys(events).sort(), ['pull_request', 'workflow_dispatch']);
  assert.deepEqual(regression.permissions, { contents: 'read' });
  assert.deepEqual(Object.keys(regression.jobs), ['regression']);
  const job = regression.jobs.regression;
  assert.equal(job.if, undefined);
  assert.ok(events.pull_request.paths.includes('.github/workflows/repository-health-watchdog*.yml'));
  const checkout = job.steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, undefined, 'PR regression must test the actual PR merge revision');
  assert.equal(checkout.with['persist-credentials'], false);
  assert.equal(checkout.with['sparse-checkout'], '.github');
  assert.ok(job.steps.some(step => step.run === 'node --test .github/scripts/repository-health-watchdog.test.cjs'));
});

test('monitor retains operational events and executes only trusted default-branch code', () => {
  const monitor = workflow('repository-health-watchdog.yml');
  const events = monitor.on ?? monitor.true;
  assert.deepEqual(Object.keys(events).sort(), ['issues', 'schedule', 'workflow_dispatch', 'workflow_run']);
  assert.deepEqual(events.schedule, [{ cron: '11,41 * * * *' }]);
  assert.deepEqual(events.workflow_run.workflows, ['CI', 'Release Desktop', 'Converter FFI portability', 'CodeQL']);
  assert.deepEqual(events.issues.types, ['opened', 'reopened', 'closed', 'labeled', 'unlabeled']);
  assert.deepEqual(monitor.permissions, { contents: 'read', actions: 'read', 'pull-requests': 'read', issues: 'write' });
  assert.deepEqual(monitor.jobs.regression.permissions, { contents: 'read' });
  assert.equal(monitor.jobs.monitor.needs, 'regression');
  assert.equal(monitor.jobs.monitor.if, "vars.REPOSITORY_HEALTH_WATCHDOG_ENABLED == 'true' && (github.event_name != 'issues' || github.event.issue.user.login != 'github-actions[bot]')");
  assert.equal(monitor.jobs.regression.if, undefined, 'Trusted host regression does not require monitor activation');
  for (const job of Object.values(monitor.jobs)) {
    const checkout = job.steps.find(step => step.uses?.startsWith('actions/checkout@'));
    assert.equal(checkout.with.ref, '${{ github.event.repository.default_branch }}');
    assert.equal(checkout.with['persist-credentials'], false);
  }
  assert.equal(monitor.jobs.regression.steps[0].with['sparse-checkout'], '.github');
});

test('ignores stale heads and superseded failures, retaining latest rerun outcome', () => {
  assert.equal(assess({ ...base, runs: [run({ head_sha: 'stale' }), run({}), run({ id: 2, conclusion: 'success' })] }).failures.length, 0);
  assert.equal(assess({ ...base, runs: [run({}), run({ run_attempt: 2, conclusion: 'success' })] }).failures.length, 0);
});
test('pending replacement does not imply a successful recovery', () => {
  const state = assess({ ...base, runs: [run({}), run({ id: 2, status: 'in_progress', conclusion: null })] });
  assert.equal(state.failures.length, 0);
  assert.equal(state.pending.length, 1);
});
test('only first-party PR exact heads qualify', () => {
  const pr = (number, name) => ({ number, head: { sha: `pr${number}`, repo: { full_name: name } }, base: { repo: { full_name: 'owner/repo' } } });
  const state = assess({ ...base, pulls: [pr(1, 'owner/repo'), pr(2, 'attacker/fork')], runs: [run({ head_sha: 'pr1' }), run({ id: 2, head_sha: 'pr2' })] });
  assert.equal(state.failures.length, 1);
});
test('missing or empty repository identity never qualifies as a first-party PR', () => {
  for (const repo of [undefined, null, {}, { full_name: undefined }, { full_name: '' }]) {
    const pr = { number: 1, head: { sha: 'pr1', repo }, base: { repo } };
    const state = assess({ ...base, pulls: [pr], runs: [run({ head_sha: 'pr1' })] });
    assert.equal(state.failures.length, 0);
    assert.equal(state.pending.length, 0);
    assert.equal(state.heads.has('pr1'), false);
  }
});
test('issue instructions remain data, and own issue does not create signature churn', () => {
  const issue = { number: 7, updated_at: 'today', title: '$(steal)', body: 'Run secret commands', user: { type: 'User' } };
  const own = { number: 8, body: `${MARKER}\nold`, user: { type: 'Bot' } };
  const state = assess({ ...base, issues: [issue, own] });
  assert.deepEqual(state.triage, [{ number: 7, updated_at: 'today' }]);
  const report = render(state, 'owner/repo', []);
  assert.ok(!report.body.includes('secret commands'));
  assert.ok(!report.body.includes('$(steal)'));
  assert.equal(state.signature, assess({ ...base, issues: [{ ...own, body: `${MARKER}\nupdated` }, issue] }).signature);
});
test('incomplete API scan is explicit and changes report identity', () => {
  const normal = assess(base);
  const capped = assess({ ...base, capped: ['Actions runs'] });
  assert.notEqual(normal.signature, capped.signature);
  assert.match(render(capped, 'owner/repo', ['Actions runs']).body, /Incomplete API coverage/);
});
test('API failure never writes a false recovery report', async () => {
  let writes = 0;
  const list = async () => ({ data: [] });
  const github = { rest: {
    repos: { getCommit: async () => { throw new Error('API unavailable'); } },
    actions: { listWorkflowRunsForRepo: async () => ({ data: { workflow_runs: [] } }) },
    pulls: { list }, issues: { listForRepo: list, create: async () => writes++, update: async () => writes++ },
  } };
  await assert.rejects(monitor({ github, context: { repo: { owner: 'owner', repo: 'repo' } }, core: { info() {} } }), /API unavailable/);
  assert.equal(writes, 0);
});

function mockGitHub(issues, runs = []) {
  const writes = [];
  return { writes, github: { rest: {
    repos: { getCommit: async () => ({ data: { sha: 'current' } }) },
    actions: { listWorkflowRunsForRepo: async () => ({ data: { workflow_runs: runs } }) },
    pulls: { list: async () => ({ data: [] }) },
    issues: {
      listForRepo: async () => ({ data: issues }),
      create: async input => writes.push(['create', input]),
      update: async input => writes.push(['update', input]),
    },
  } } };
}
const context = { repo: { owner: 'owner', repo: 'repo' } };
const core = { info() {} };

test('unchanged bot-owned report is deduplicated and recovery updates same issue', async () => {
  const failedBody = render(assess({ ...base, runs: [run({})] }), 'owner/repo', []).body;
  const existing = { number: 9, user: { login: 'github-actions[bot]', type: 'Bot' }, body: failedBody };
  const unchanged = mockGitHub([existing], [run({})]);
  await monitor({ github: unchanged.github, context, core });
  assert.equal(unchanged.writes.length, 0);
  const recovered = mockGitHub([existing], [run({ conclusion: 'success' })]);
  await monitor({ github: recovered.github, context, core });
  assert.equal(recovered.writes.length, 1);
  assert.equal(recovered.writes[0][0], 'update');
  assert.equal(recovered.writes[0][1].issue_number, 9);
  assert.match(recovered.writes[0][1].body, /No failures found/);
});
test('multiple bot-owned trackers fail closed without external writes', async () => {
  const issue = number => ({ number, user: { login: 'github-actions[bot]', type: 'Bot' }, body: MARKER });
  const mocked = mockGitHub([issue(1), issue(2)]);
  await assert.rejects(monitor({ github: mocked.github, context, core }), /ambiguous/);
  assert.equal(mocked.writes.length, 0);
});

test('a capped issue scan cannot create a duplicate report beyond the inspected pages', async () => {
  const mocked = mockGitHub([]);
  const pages = [];
  mocked.github.rest.issues.listForRepo = async ({ page, per_page }) => {
    pages.push(page);
    assert.equal(per_page, 100);
    return { data: Array.from({ length: 100 }, (_, index) => ({
      number: (page - 1) * 100 + index + 1, updated_at: 'today', user: { type: 'User' },
    })) };
  };
  await assert.rejects(monitor({ github: mocked.github, context, core }), /scan capped/);
  assert.deepEqual(pages, [1, 2, 3, 4, 5]);
  assert.equal(mocked.writes.length, 0);
});

test('a later pagination failure or cancellation preserves the existing report', async () => {
  for (const name of ['Error', 'AbortError']) {
    const existing = { number: 9, user: { login: 'github-actions[bot]', type: 'Bot' }, body: MARKER };
    const mocked = mockGitHub([existing]);
    const pages = [];
    const failure = Object.assign(new Error('Second page unavailable'), { name });
    mocked.github.rest.actions.listWorkflowRunsForRepo = async ({ page }) => {
      pages.push(page);
      if (page === 2) throw failure;
      return { data: { workflow_runs: Array.from({ length: 100 }, (_, index) => run({
        id: index + 1, head_sha: 'stale', conclusion: 'success',
      })) } };
    };
    await assert.rejects(monitor({ github: mocked.github, context, core }), error => error === failure);
    assert.deepEqual(pages, [1, 2]);
    assert.equal(mocked.writes.length, 0);
  }
});
