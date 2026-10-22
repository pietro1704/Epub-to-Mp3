'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { publish } = require('./pr-repair-safety.cjs');

const REPOSITORY = 'pietro1704/epub-to-mp3';
const SHA = 'a'.repeat(40);
const BASE_SHA = 'c'.repeat(40);
const PREPARED = { writers: true, credentials: true };
function withFailure(api, sha = SHA, runs) {
  const values = runs || [{ id: 101, run_attempt: 1, workflow_id: 42, head_sha: sha,
    head_repository: { full_name: REPOSITORY }, event: 'pull_request', status: 'completed', conclusion: 'failure' }];
  return (endpoint, method, body) => {
    if (endpoint === '/actions/workflows/ci.yml') return { id: 42, name: 'CI', path: '.github/workflows/ci.yml' };
    if (endpoint.startsWith('/actions/workflows/ci.yml/runs?head_sha=')) return { total_count: values.length, workflow_runs: values };
    return api(endpoint, method, body);
  };
}
function pr(sha = SHA) {
  return { number: 7, state: 'open', draft: false, user: { login: 'pietro1704', type: 'User' },
    head: { sha, ref: 'feature/repair', repo: { full_name: REPOSITORY } },
    base: { ref: 'master', sha: BASE_SHA, repo: { full_name: REPOSITORY } } };
}

function claimComment(sha, run = '123') {
  return { user: { login: 'github-actions[bot]', type: 'Bot' },
    body: `<!-- pr-repair-attempt:v1:${sha} -->\nRepair attempt claimed by trusted worker run ${run}. This is not a successful repair or verification claim.` };
}

function authorizedPublish({ api, ...options }) {
  return publish({ ...options, writers: true, credentials: true, run: '123',
    api: (endpoint, method, body) => endpoint.startsWith('/issues/7/comments?') ?
      [claimComment(options.expected)] : api(endpoint, method, body) });
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pr repair fixture '));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const remote = path.join(root, 'remote.git'), work = path.join(root, 'work');
  const git = (cwd, ...args) => {
    const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git(root, 'init', '--bare', remote); git(root, 'init', work);
  git(work, 'config', 'user.name', 'Fixture'); git(work, 'config', 'user.email', 'fixture@example.invalid');
  fs.mkdirSync(path.join(work, 'src')); fs.writeFileSync(path.join(work, 'src/value.txt'), 'before\n');
  git(work, 'add', '.'); git(work, '-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'fixture');
  git(work, 'branch', '-M', 'feature/repair'); git(work, 'remote', 'add', 'origin', remote);
  git(work, 'push', 'origin', 'feature/repair');
  const expected = git(work, 'rev-parse', 'HEAD'); git(work, 'checkout', '--detach', expected);
  return { root, remote, work, git, expected };
}

module.exports = { REPOSITORY, SHA, BASE_SHA, PREPARED, withFailure, pr, claimComment, authorizedPublish, fixture };
