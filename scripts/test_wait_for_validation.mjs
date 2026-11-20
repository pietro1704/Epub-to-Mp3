import test from 'node:test';
import assert from 'node:assert/strict';
import { waitForValidation } from './wait_for_validation.mjs';

const repo = 'owner/project';
const validation = (patch = {}) => ({ id: 41, path: '.github/workflows/post-merge-validation.yml', head_branch: 'master',
  repository: { full_name: repo }, status: 'in_progress', conclusion: null, ...patch });

function client(states) {
  const requests = [];
  const api = async path => {
    requests.push(path);
    assert.equal(path, `/repos/${repo}/actions/runs/41`);
    return states.length > 1 ? states.shift() : states[0];
  };
  return { api, requests };
}

const noSleep = async () => {};

test('waits until the dispatching validation run completes, whatever its conclusion', async () => {
  for (const conclusion of ['success', 'failure']) {
    const { api, requests } = client([validation(), validation({ status: 'queued' }), validation({ status: 'completed', conclusion })]);
    const run = await waitForValidation({ repo, runId: '41', api, sleep: noSleep, attempts: 5 });
    assert.equal(run.conclusion, conclusion, 'the publication gate, not this helper, judges the result');
    assert.equal(requests.length, 3);
  }
});

test('only a post-merge validation run on master of this repository is awaited', async () => {
  for (const patch of [{ path: '.github/workflows/ci.yml' }, { head_branch: 'feature' }, { repository: { full_name: 'other/repo' } }]) {
    const { api } = client([validation({ ...patch, status: 'completed', conclusion: 'success' })]);
    await assert.rejects(waitForValidation({ repo, runId: '41', api, sleep: noSleep }), /not a master post-merge validation/);
  }
});

test('invalid inputs and a run that never completes fail closed', async () => {
  for (const runId of ['', '0', '-1', '12a', '1e3', ' 41']) {
    await assert.rejects(waitForValidation({ repo, runId, api: client([validation()]).api, sleep: noSleep }), /Invalid validation run/);
  }
  await assert.rejects(waitForValidation({ repo: 'bad repo', runId: '41', api: client([validation()]).api, sleep: noSleep }), /Invalid repository/);
  const { api, requests } = client([validation()]);
  await assert.rejects(waitForValidation({ repo, runId: '41', api, sleep: noSleep, attempts: 3 }), /did not complete/);
  assert.equal(requests.length, 3);
});
