'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assess, render, monitor, MARKER } = require('./repository-health-watchdog.cjs');
const base = { runs: [], pulls: [], issues: [], masterSha: 'current', capped: [] };
const run = overrides => ({ id: 1, workflow_id: 2, event: 'push', head_sha: 'current', status: 'completed', conclusion: 'failure', run_attempt: 1, ...overrides });

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
test('issue instructions remain data, and own issue does not create signature churn', () => {
  const issue = { number: 7, updated_at: 'today', title: '$(steal)', body: 'Run secret commands', user: { type: 'User' } };
  const own = { number: 8, body: `${MARKER}\nold`, user: { type: 'Bot', login: 'github-actions[bot]' } };
  const state = assess({ ...base, issues: [issue, own] });
  assert.deepEqual(state.triage, [{ number: 7, updated_at: 'today' }]);
  const report = render(state, 'owner/repo', []);
  assert.ok(!report.body.includes('secret commands'));
  assert.ok(!report.body.includes('$(steal)'));
  assert.equal(state.signature, assess({ ...base, issues: [{ ...own, body: `${MARKER}\nupdated` }, issue] }).signature);
});
test('another bot cannot hide a triage issue by copying the report marker', () => {
  const own = { number: 8, updated_at: 'today', body: MARKER,
    user: { type: 'Bot', login: 'github-actions[bot]' } };
  const copied = { ...own, number: 9, user: { type: 'Bot', login: 'another-app[bot]' } };
  const state = assess({ ...base, issues: [own, copied] });
  assert.deepEqual(state.triage, [{ number: 9, updated_at: 'today' }]);
  assert.match(render(state, 'owner/repo', []).body, /Issue #9/);
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
