import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { evaluate, guardedMerge } from './guarded_pr_merge.mjs';
const repo = 'pietro1704/Epub-to-Mp3';
const head = 'a'.repeat(40);

for (const state of ['CLEAN', 'BEHIND']) {
  test(`scheduled policy only inspects ${state} candidates without GitHub mutations`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'pr-policy-inspection-'));
    try {
      mkdirSync(join(directory, 'scripts'));
      writeFileSync(join(directory, 'scripts/guarded_pr_merge.mjs'),
        readFileSync(new URL('./guarded_pr_merge.mjs', import.meta.url)));
      const data = fixture();
      data.pr.mergeStateStatus = state;
      writeFileSync(join(directory, 'fixture.json'), JSON.stringify({ ...data, candidates: [{
        number: 802, isDraft: false, author: { login: 'pietro1704' },
        headRepository: { nameWithOwner: repo }, headRefName: 'feature/example',
        headRefOid: head, mergeStateStatus: state,
      }] }));
      const fakeGh = join(directory, 'gh');
      writeFileSync(fakeGh, `#!${process.execPath}\n` + String.raw`
const fs = require('node:fs');
const args = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync('fixture.json', 'utf8'));
fs.appendFileSync('calls.jsonl', JSON.stringify(args) + '\n');
let response;
if (args[0] === 'pr' && args[1] === 'list') response = data.candidates;
else if (args[0] === 'pr' && args[1] === 'view') response = data.pr;
else if (args[0] === 'pr' && args[1] === 'merge') response = {};
else if (args[0] === 'workflow' && args[1] === 'run') response = {};
else if (args[0] === 'api' && args.includes('--method')) response = {};
else if (args[0] === 'api' && args.at(-1).includes('/compare/')) response = data.comparison;
else if (args[0] === 'api' && args.at(-1).includes('/actions/workflows/')) {
  response = [{ workflow_runs: args.at(-1).includes('codeql.yml') ? data.securityRuns : data.runs }];
} else { console.error('Unexpected fake GitHub command'); process.exit(97); }
process.stdout.write(JSON.stringify(response));
`);
      chmodSync(fakeGh, 0o700);
      const workflow = readFileSync(new URL('../.github/workflows/auto-merge-dependabot.yml', import.meta.url), 'utf8');
      const block = workflow.match(/^        run: \|\n((?:          .*\n|\n)+)/m);
      assert.ok(block, 'scheduled workflow shell entry point must exist');
      const script = block[1].replace(/^          /gm, '');
      const result = spawnSync('bash', ['-c', script], {
        cwd: directory, encoding: 'utf8', timeout: 15000, maxBuffer: 65536,
        env: { PATH: `${directory}:${process.env.PATH}`, REPO: repo,
          GITHUB_TOKEN: 'fake-token-only', GITHUB_RUN_ID: '90', HOME: directory },
      });
      assert.ifError(result.error);
      assert.equal(result.signal, null);
      assert.equal(result.status, 0, result.stderr);
      const calls = readFileSync(join(directory, 'calls.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line));
      assert.ok(calls.some(args => args[0] === 'pr' && args[1] === 'view'), 'real helper must inspect the candidate');
      const mutations = calls.filter(args =>
        (args[0] === 'pr' && args[1] === 'merge') ||
        (args[0] === 'workflow' && args[1] === 'run') ||
        (args[0] === 'api' && args.some(value => ['PUT', 'POST', 'PATCH', 'DELETE'].includes(value))));
      assert.deepEqual(mutations, [], 'scheduled policy must not merge, update branches or dispatch workflows');
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}

function fixture() {
  return { repo, head, runId: '90', comparison: { status: 'ahead', behind_by: 0 }, pr: { state: 'OPEN', isDraft: false, baseRefName: 'master', headRefOid: head,
    isCrossRepository: false, reviewDecision: '', mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN', statusCheckRollup: [
      { __typename: 'CheckRun', name: 'Python', workflowName: 'CI', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { __typename: 'CheckRun', name: 'CodeQL', status: 'COMPLETED', conclusion: 'SUCCESS' },
    ] }, runs: [{ id: 80, head_sha: head, status: 'completed', conclusion: 'success' }],
    securityRuns: [{ id: 81, head_sha: head, status: 'completed', conclusion: 'success' }] };
}
test('exact-head successful complete CI and every observed check permit merge', () => {
  const f = fixture();
  assert.equal(evaluate(f).eligible, true);
  f.pr.statusCheckRollup.push({ __typename: 'StatusContext', state: 'SUCCESS' });
  assert.equal(evaluate(f).eligible, true);
});
test('pending, failed, cancelled, skipped, neutral or unknown checks block merge', () => {
  for (const conclusion of ['FAILURE', 'CANCELLED', 'SKIPPED', 'NEUTRAL', 'TIMED_OUT', null, 'OTHER']) {
    const f = fixture(); f.pr.statusCheckRollup[1].conclusion = conclusion;
    assert.equal(evaluate(f).eligible, false);
  }
  for (const status of ['QUEUED', 'IN_PROGRESS', null]) {
    const f = fixture(); f.pr.statusCheckRollup[1].status = status;
    assert.equal(evaluate(f).eligible, false);
  }
  for (const check of [{ __typename: 'StatusContext', state: 'PENDING' }, {}, { __typename: 'Unknown', conclusion: 'SUCCESS' }]) {
    const f = fixture(); f.pr.statusCheckRollup.push(check);
    assert.equal(evaluate(f).eligible, false);
  }
});
test('a single green CI job cannot hide unfinished or failed whole workflow', () => {
  for (const [status, conclusion] of [['in_progress', null], ['queued', null], ['completed', 'failure'], ['completed', 'cancelled']]) {
    const f = fixture(); Object.assign(f.runs[0], { status, conclusion });
    assert.equal(evaluate(f).eligible, false);
  }
  const f = fixture();
  f.runs.push({ id: 81, head_sha: head, status: 'queued', conclusion: null });
  assert.equal(evaluate(f).eligible, false, 'latest CI run must be complete, even after an older success');
});
test('zero checks or missing CI evidence fails closed without branch protection', () => {
  for (const checks of [[], null, undefined]) {
    const f = fixture(); f.pr.statusCheckRollup = checks;
    assert.equal(evaluate(f).eligible, false);
  }
  for (const runs of [[], null, [{ id: 80, head_sha: 'b'.repeat(40), status: 'completed', conclusion: 'success' }]]) {
    const f = fixture(); f.runs = runs;
    assert.equal(evaluate(f).eligible, false);
  }
});
test('drafts, forks, closed PRs, review rejection and changed heads block merge', () => {
  for (const changed of [{ isDraft: true }, { isCrossRepository: true }, { isCrossRepository: null }, { state: 'MERGED' },
    { baseRefName: 'develop' }, { reviewDecision: 'CHANGES_REQUESTED' }, { headRefOid: 'b'.repeat(40) }]) {
    const f = fixture(); Object.assign(f.pr, changed);
    assert.equal(evaluate(f).eligible, false);
  }
});
test('exclude only this automation run to avoid waiting for itself, never another run', () => {
  const f = fixture();
  const own = { __typename: 'CheckRun', status: 'IN_PROGRESS', conclusion: null,
    detailsUrl: `https://github.com/${repo}/actions/runs/90/job/12` };
  f.pr.statusCheckRollup.push(own);
  assert.equal(evaluate(f).eligible, true);
  for (const url of [`https://github.com/${repo}/actions/runs/901/job/12`, `https://evil.test/${repo}/actions/runs/90/job/12`,
    'not a URL', `https://github.com/other/repo/actions/runs/90/job/12`]) {
    own.detailsUrl = url;
    assert.equal(evaluate(f).eligible, false);
  }
  f.pr.statusCheckRollup = [{ ...own, detailsUrl: `https://github.com/${repo}/actions/runs/90/job/12` }];
  assert.equal(evaluate(f).eligible, false, 'self exclusion cannot manufacture a nonempty successful check set');
});
function harness(options = {}) {
  const data = fixture();
  const calls = [];
  let reads = 0;
  return { calls, data, run(merge = true) {
    return guardedMerge({ repo, pr: '802', head, runId: '90', merge, invoke(args) {
      calls.push(args);
      if (options.failCall === calls.length) throw new Error('private metadata');
      if (args[0] === 'api' && args.at(-1).includes('/compare/')) return JSON.stringify(data.comparison);
      if (args[0] === 'api') return options.badPages ? '{}' : JSON.stringify([{ workflow_runs: args.at(-1).includes('codeql.yml') ? data.securityRuns : data.runs }]);
      if (args[1] === 'view') {
        reads++;
        if (options.changeOnRecheck && reads === 2) data.pr.headRefOid = 'b'.repeat(40);
        if (options.failOnRecheck && reads === 2) data.pr.statusCheckRollup[1].conclusion = 'FAILURE';
        if (options.securityOnRecheck && reads === 2) data.securityRuns[0].status = 'in_progress';
        if (options.baseOnRecheck && reads === 2) data.pr.mergeStateStatus = 'BEHIND';
        return JSON.stringify(data.pr);
      }
      return '';
    } });
  } };
}
test('mutation is explicitly requested, twice verified and pinned to approved head', () => {
  const h = harness(); const report = h.run();
  assert.deepEqual(h.calls.at(-1), ['pr', 'merge', '802', '--repo', repo, '--squash', '--match-head-commit', head]);
  assert.equal(h.calls.length, 9);
  assert.equal(report.merge_requested, true);
  assert.equal(report.merged, false, 'accepted command is not proof of merged delivery');
  assert.ok(!h.calls.flat().some(value => ['--auto', '--admin', '--delete-branch'].includes(value)));
});
test('read-only mode never mutates; changed head or checks on reread never merge', () => {
  for (const options of [{ changeOnRecheck: true }, { failOnRecheck: true }, { securityOnRecheck: true }, { baseOnRecheck: true }]) {
    const h = harness(options);
    assert.equal(h.run().eligible, false);
    assert.equal(h.calls.some(args => args[1] === 'merge'), false);
  }
  const h = harness(); assert.equal(h.run(false).merged, false); assert.equal(h.calls.length, 4);
});
test('infrastructure failures and malformed metadata have no mutation fallback', () => {
  for (const options of [{ failCall: 1 }, { failCall: 2 }, { failCall: 3 }, { failCall: 4 }, { failCall: 5 }, { failCall: 6 }, { failCall: 7 }, { failCall: 8 }, { badPages: true }]) {
    const h = harness(options); assert.throws(() => h.run());
    assert.equal(h.calls.some(args => args[1] === 'merge'), false);
  }
});
test('argument injection and non-scalar identifiers fail before any command', () => {
  for (const changed of [{ repo: 'repo;evil' }, { pr: '-1' }, { pr: ['802'] }, { head: [head] }, { head: 'B'.repeat(40) }]) {
    assert.throws(() => guardedMerge({ repo, pr: '802', head, ...changed, invoke: () => assert.fail('must not run') }));
  }
});
test('policy inspection uses the trusted base and the repair worker cannot merge', () => {
  for (const filename of ['auto-merge-dependabot.yml', 'pr-autofix-worker.yml']) {
    const text = readFileSync(new URL(`../.github/workflows/${filename}`, import.meta.url), 'utf8');
    assert.match(text, /ref: master/);
    assert.match(text, /persist-credentials: false/);
    if (filename === 'pr-autofix-worker.yml') {
      assert.doesNotMatch(text, /guarded_pr_merge|automerge:|inputs\.mode/);
    } else {
      assert.match(text, /node scripts\/guarded_pr_merge\.mjs/);
    }
    assert.doesNotMatch(text, /--merge/);
    assert.doesNotMatch(text, /gh pr merge/);
  }
  const gate = readFileSync(new URL('../.github/workflows/merge-policy.yml', import.meta.url), 'utf8');
  assert.match(gate, /node --test scripts\/test_guarded_pr_merge\.mjs/);
  assert.match(gate, /pull_request:/);
});

test('behind, dirty, blocked or unknown mergeability and base freshness fail closed', () => {
  for (const changed of [{ mergeable: 'CONFLICTING' }, { mergeable: 'UNKNOWN' }, { mergeable: null },
    { mergeStateStatus: 'BEHIND' }, { mergeStateStatus: 'DIRTY' }, { mergeStateStatus: 'UNKNOWN' },
    { mergeStateStatus: 'BLOCKED' }, { mergeStateStatus: null }]) {
    const f = fixture(); Object.assign(f.pr, changed);
    assert.equal(evaluate(f).eligible, false, JSON.stringify(changed));
  }
});
test('missing or incomplete exact-head CodeQL evidence blocks otherwise green CI', () => {
  for (const securityRuns of [undefined, [],
    [{ id: 81, head_sha: head, status: 'queued', conclusion: null }],
    [{ id: 81, head_sha: head, status: 'in_progress', conclusion: null }],
    [{ id: 81, head_sha: head, status: 'completed', conclusion: 'failure' }],
    [{ id: 81, head_sha: head, status: 'completed', conclusion: 'cancelled' }],
    [{ id: 81, head_sha: 'b'.repeat(40), status: 'completed', conclusion: 'success' }]]) {
    const f = fixture(); f.securityRuns = securityRuns;
    assert.equal(evaluate(f).eligible, false);
  }
  const f = fixture();
  f.securityRuns.push({ id: 82, head_sha: head, status: 'queued', conclusion: null });
  assert.equal(evaluate(f).eligible, false, 'a newer CodeQL rerun invalidates an older success');
});
test('non-green security and stale base never reach a merge mutation', () => {
  for (const change of ['security', 'base']) {
    const h = harness();
    if (change === 'security') h.data.securityRuns = [];
    else h.data.pr.mergeStateStatus = 'BEHIND';
    assert.equal(h.run().eligible, false);
    assert.equal(h.calls.some(args => args[1] === 'merge'), false);
  }
});

test('every workflow writer uses the trusted gate or leaves automatic merge disabled', () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  for (const filename of readdirSync(directory).filter(name => /\.ya?ml$/.test(name))) {
    const text = readFileSync(new URL(filename, directory), 'utf8');
    assert.doesNotMatch(text, /\bgh\s+pr\s+merge\b|\bpulls\.merge\s*\(|\/pulls\/[^\s]+\/merge\b/, filename);
  }
  for (const filename of ['code-scanning-remediation.yml', 'dependency-vulnerability-remediation.yml', 'issue-remediation.yml']) {
    const text = readFileSync(new URL(filename, directory), 'utf8');
    assert.match(text, /Auto-merge disabled/);
    assert.match(text, /trusted master scripts\/guarded_pr_merge\.mjs/);
  }
});

test('freshness requires an actual current master ancestry comparison', () => {
  for (const comparison of [undefined, {}, { status: 'ahead', behind_by: 1 },
    { status: 'behind', behind_by: 1 }, { status: 'diverged', behind_by: 2 },
    { status: 'ahead', behind_by: '0' }]) {
    const f = fixture(); f.comparison = comparison;
    assert.equal(evaluate(f).eligible, false);
  }
  const f = fixture(); f.comparison.status = 'identical';
  assert.equal(evaluate(f).eligible, true);
});
