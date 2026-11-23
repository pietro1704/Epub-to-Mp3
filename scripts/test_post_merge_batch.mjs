import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { decideBatch, FORCE_AFTER_MS } from './post_merge_batch.mjs';

const head = 'a'.repeat(40), older = 'b'.repeat(40);
const now = Date.parse('2026-11-23T21:00:00Z');
const run = (patch = {}) => ({ head_sha: older, status: 'completed', conclusion: 'success', created_at: '2026-11-23T20:50:00Z', ...patch });

test('an unvalidated head with an idle CI starts one validation', () => {
  assert.deepEqual(decideBatch({ head, runs: [run()], prCiActive: 0, now }).dispatch, true);
  assert.equal(decideBatch({ head, runs: [], prCiActive: 3, now }).dispatch, true, 'no history: validate');
});

test('nothing starts while a validation runs, or when the head is validated or already failed', () => {
  for (const status of ['queued', 'in_progress', 'pending', 'waiting']) {
    assert.equal(decideBatch({ head, runs: [run({ status, conclusion: null })], prCiActive: 0, now }).dispatch, false, status);
  }
  assert.equal(decideBatch({ head, runs: [run({ head_sha: head })], prCiActive: 0, now }).dispatch, false);
  assert.equal(decideBatch({ head, runs: [run({ head_sha: head, conclusion: 'failure' })], prCiActive: 0, now }).dispatch, false);
  assert.equal(decideBatch({ head, runs: [run({ head_sha: head, conclusion: 'cancelled' })], prCiActive: 0, now }).dispatch, true, 'a cancelled run does not validate');
});

test('pull request checks go first, but a validation older than the forced interval starts anyway', () => {
  assert.equal(decideBatch({ head, runs: [run()], prCiActive: 2, now }).dispatch, false);
  const old = run({ created_at: new Date(now - FORCE_AFTER_MS - 1000).toISOString() });
  assert.equal(decideBatch({ head, runs: [old], prCiActive: 2, now }).dispatch, true);
});

test('invalid input never dispatches', () => {
  assert.throws(() => decideBatch({ head: 'x', runs: [], prCiActive: 0 }), /Invalid master head/);
  assert.throws(() => decideBatch({ head, runs: null, prCiActive: 0 }), /Incomplete/);
  assert.throws(() => decideBatch({ head, runs: [], prCiActive: -1 }), /Incomplete/);
});

test('the workflows wire the batch and no longer start validation per merge', () => {
  const parse = file => JSON.parse(spawnSync('ruby', ['-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: false))',
    new URL(`../.github/workflows/${file}`, import.meta.url).pathname], { encoding: 'utf8' }).stdout);
  const post = parse('post-merge-validation.yml');
  const triggers = post.on ?? post.true;
  assert.equal(triggers.push, undefined);
  assert.equal(triggers.workflow_dispatch.inputs.scoped.default, false);
  assert.equal(post.jobs.scope.steps.find(step => step.id === 'scope').env.SCOPED_DISPATCH, '${{ inputs.scoped == true }}');
  const batch = parse('post-merge-batch.yml');
  const events = batch.on ?? batch.true;
  assert.deepEqual(events.schedule, [{ cron: '*/20 * * * *' }]);
  assert.equal(events.workflow_dispatch.inputs.dry_run.default, true);
  assert.deepEqual(batch.permissions, { contents: 'read', actions: 'write' });
  const script = readFileSync(new URL('./post_merge_batch.mjs', import.meta.url), 'utf8');
  assert.match(script, /'workflow', 'run', 'post-merge-validation\.yml'.*'-f', 'scoped=true'/);
  assert.doesNotMatch(readFileSync(new URL('../.github/workflows/auto-merge-dependabot.yml', import.meta.url), 'utf8'), /gh workflow run post-merge-validation/);
});
