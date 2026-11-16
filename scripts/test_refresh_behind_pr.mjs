import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { refresh, select } from './refresh_behind_pr.mjs';
const repo = 'pietro1704/Epub-to-Mp3';
const sha = (c) => c.repeat(40);
const pr = (number, changes = {}) => ({ number, isDraft: false, baseRefName: 'master', headRefOid: sha('a'),
  isCrossRepository: false, reviewDecision: '', mergeStateStatus: 'BEHIND',
  statusCheckRollup: [{ name: 'PR gate', status: 'COMPLETED', conclusion: 'SUCCESS' }], ...changes });

test('refreshes only the oldest eligible behind pull request', () => {
  assert.deepEqual(select([pr(9, { headRefOid: sha('b') }), pr(4)]), { refresh: 4, head: sha('a') });
});
test('waits while a current pull request still runs its gate', () => {
  const running = pr(2, { mergeStateStatus: 'BLOCKED',
    statusCheckRollup: [{ name: 'PR gate', status: 'IN_PROGRESS', conclusion: null }] });
  assert.equal(select([running, pr(5)]).reason, 'pr_in_flight');
});
test('drafts, forks, conflicts, requested changes and failed gates are never refreshed', () => {
  for (const changes of [{ isDraft: true }, { isCrossRepository: true }, { mergeStateStatus: 'DIRTY' },
    { mergeStateStatus: 'CLEAN' }, { reviewDecision: 'CHANGES_REQUESTED' }, { baseRefName: 'release' },
    { headRefOid: 'bad' }, { statusCheckRollup: [{ name: 'PR gate', status: 'COMPLETED', conclusion: 'FAILURE' }] }]) {
    assert.equal(select([pr(3, changes)]).refresh, null, JSON.stringify(changes));
  }
  assert.equal(select([pr(3, { statusCheckRollup: [] })]).refresh, 3);
});
test('update is pinned to the inspected head and never merges', () => {
  const calls = [];
  const result = refresh({ repo, invoke: (args) => { calls.push(args); return args[0] === 'pr' ? JSON.stringify([pr(7)]) : '{}'; } });
  assert.equal(result.update_requested, true);
  assert.deepEqual(calls[1], ['api', '-X', 'PUT', '-f', `expected_head_sha=${sha('a')}`, `repos/${repo}/pulls/7/update-branch`]);
  assert.equal(calls.some(args => args.includes('merge')), false);
});
test('merge workflow refreshes behind pull requests after the guarded merge pass', () => {
  const text = readFileSync(new URL('../.github/workflows/auto-merge-dependabot.yml', import.meta.url), 'utf8');
  assert.ok(text.indexOf('guarded_pr_merge.mjs') < text.indexOf('node scripts/refresh_behind_pr.mjs'));
  assert.match(text, /PR_BRANCH_UPDATE_TOKEN:/);
  assert.match(text, /schedule:/);
});
