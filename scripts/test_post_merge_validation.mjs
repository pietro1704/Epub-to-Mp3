import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { verifyMergeIdentity, assertValidationResults, inspectMergedSource, REQUIRED_VALIDATIONS } from './post_merge_validation.mjs';

const repo = 'pietro1704/Epub-to-Mp3';
const sha = 'a'.repeat(40);
function fixture() {
  return { repo, sha, master: sha, event: 'push', ref: 'refs/heads/master', comparison: { status: 'identical', ahead_by: 0 },
    pulls: [{ number: 887, state: 'closed', merged_at: '2026-10-20T16:34:11Z', merge_commit_sha: sha,
      base: { ref: 'master', repo: { full_name: repo } } }] };
}

test('exact confirmed merge and an older reachable merge may be validated', () => {
  assert.equal(verifyMergeIdentity(fixture()).sha, sha);
  const f = fixture(); f.master = 'b'.repeat(40); f.comparison.status = 'behind';
  assert.equal(verifyMergeIdentity(f).master, f.master);
});

test('PR heads, unmerged changes and wrong repository or merge identities fail closed', () => {
  for (const patch of [{ event: 'pull_request' }, { ref: 'refs/heads/feature/example' }, { sha: 'invalid' }, { pulls: [] },
    { comparison: { status: 'diverged', ahead_by: 1 } }, { comparison: { status: 'behind', ahead_by: '0' } }]) {
    assert.throws(() => verifyMergeIdentity({ ...fixture(), ...patch }));
  }
  for (const patch of [{ state: 'open' }, { merged_at: null }, { merge_commit_sha: 'b'.repeat(40) },
    { base: { ref: 'develop', repo: { full_name: repo } } }, { base: { ref: 'master', repo: { full_name: 'other/repo' } } }]) {
    const f = fixture(); Object.assign(f.pulls[0], patch); assert.throws(() => verifyMergeIdentity(f));
  }
});

test('every required validation must complete successfully before publication', () => {
  const needs = Object.fromEntries(REQUIRED_VALIDATIONS.map(name => [name, { result: 'success' }]));
  assert.equal(assertValidationResults(needs), true);
  for (const result of ['failure', 'cancelled', 'skipped', 'in_progress', undefined]) {
    assert.throws(() => assertValidationResults({ ...needs, codeql: { result } }));
  }
  for (const value of [undefined, [], {}, { ci: { result: 'success' } }]) assert.throws(() => assertValidationResults(value));
  for (const name of REQUIRED_VALIDATIONS) {
    const incomplete = { ...needs }; delete incomplete[name];
    assert.throws(() => assertValidationResults(incomplete), /Missing required validation/);
  }
});

test('read-only inspection rejects incomplete pages and propagates unavailable metadata', () => {
  const f = fixture(); const calls = [];
  const invoke = args => {
    calls.push(args);
    if (args.at(-1).includes('/git/ref/')) return { object: { sha } };
    if (args.at(-1).includes('/compare/')) return f.comparison;
    return [f.pulls];
  };
  assert.equal(inspectMergedSource({ ...f, invoke }).pull, 887);
  assert.equal(calls.length, 3);
  assert.ok(calls.every(args => args[0] === 'api' && !args.includes('--method')));
  for (const pages of [{}, [], [Array(100).fill(f.pulls[0])], [null]]) {
    assert.throws(() => inspectMergedSource({ ...f, invoke: args => args.at(-1).includes('/pulls?') ? pages : invoke(args) }));
  }
  assert.throws(() => inspectMergedSource({ ...f, invoke: () => { throw new Error('Unavailable'); } }), /Unavailable/);
});

function workflow(file) {
  const source = readFileSync(new URL(`../.github/workflows/${file}`, import.meta.url), 'utf8');
  const result = spawnSync('ruby', ['-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read, aliases: false))'], { input: source, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test('postmerge graph contains every runtime and aggregates all called workflows', () => {
  const post = workflow('post-merge-validation.yml');
  const events = post.on ?? post.true;
  assert.deepEqual(events.push.branches, ['master']);
  assert.equal(events.pull_request, undefined);
  const required = Object.keys(post.jobs).filter(name => name !== 'validated').sort();
  assert.deepEqual(required, [...REQUIRED_VALIDATIONS].sort());
  assert.deepEqual([...post.jobs.validated.needs].sort(), required);
  assert.equal(post.jobs.validated.if, 'always()');
  assert.equal(post.jobs.ci.with.full_validation, true);
  for (const job of Object.values(post.jobs)) {
    if (!job.uses) continue;
    const called = workflow(job.uses.replace('./.github/workflows/', ''));
    assert.ok(Object.hasOwn(called.on ?? called.true, 'workflow_call'), job.uses);
  }
  const finalScript = post.jobs.validated.steps.map(step => step.run ?? '').join('\n');
  assert.match(finalScript, /assertValidationResults/);
  assert.match(finalScript, /post_merge_validation\.mjs/);
});
