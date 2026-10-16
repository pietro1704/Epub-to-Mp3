'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validate, readiness, attempted, claim, validateChanges, publish, currentFailure, dispatchVerification } = require('./pr-repair-safety.cjs');
const { dispatch } = require('./pr-repair-dispatch.cjs');
const REPOSITORY = 'pietro1704/epub-to-mp3';
const SHA = 'a'.repeat(40);
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
    base: { ref: 'master', repo: { full_name: REPOSITORY } } };
}

test('readiness never simulates credentials or enables absent writers', () => {
  assert.equal(readiness({ credentials: false, writers: true }), 'blocked_credentials');
  assert.equal(readiness({ credentials: true, writers: false }), 'blocked_writers_disabled');
  assert.equal(readiness({ credentials: true, writers: true }), 'prepared');
});

test('metadata rejects stale, draft, closed, fork, wrong author and unsafe branches', () => {
  assert.equal(validate(pr(), REPOSITORY, SHA).branch, 'feature/repair');
  const bot = pr(); bot.user = { login: 'github-actions[bot]', type: 'Bot' }; bot.head.ref = 'bot/issue-7';
  assert.equal(validate(bot, REPOSITORY, SHA).branch, 'bot/issue-7');
  for (const mutate of [p => { p.draft = true; }, p => { p.state = 'closed'; },
    p => { p.head.sha = 'b'.repeat(40); }, p => { p.head.repo.full_name = 'fork/repo'; },
    p => { p.user.login = 'other'; }, p => { p.base.ref = 'develop'; },
    p => { p.head.ref = 'feature/a..b'; }, p => { p.user = { login: 'github-actions[bot]', type: 'User' }; }]) {
    const candidate = pr(); mutate(candidate);
    assert.throws(() => validate(candidate, REPOSITORY, SHA));
  }
});

test('claim is authenticated, precedes inference and deduplicates failures too', () => {
  const comments = [{ user: { login: 'other', type: 'User' }, body: `<!-- pr-repair-attempt:v1:${SHA} -->` }];
  const writes = [];
  const api = withFailure((endpoint, method, body) => {
    if (endpoint === '/pulls/7') return pr();
    if (method === 'POST') { writes.push(body); comments.push({ user: { login: 'github-actions[bot]', type: 'Bot' }, ...body }); return {}; }
    return comments;
  });
  assert.equal(attempted(comments, SHA), false);
  assert.equal(claim(api, REPOSITORY, 7, SHA, '123').state, 'claimed');
  assert.equal(claim(api, REPOSITORY, 7, SHA, '124').state, 'deduplicated');
  assert.equal(writes.length, 1);
  assert.match(writes[0].body, /not a successful repair/);
});

test('latest exact-head CI must be completed failure, never historical red or infrastructure startup', () => {
  const red = { id: 101, run_attempt: 1, workflow_id: 42, head_sha: SHA,
    head_repository: { full_name: REPOSITORY }, event: 'pull_request', status: 'completed', conclusion: 'failure' };
  for (const latest of [
    { ...red, id: 102, conclusion: 'success' },
    { ...red, id: 102, status: 'in_progress', conclusion: null },
    { ...red, id: 102, conclusion: 'startup_failure' },
    { ...red, id: 102, head_sha: 'b'.repeat(40) },
    { ...red, run_attempt: 2, conclusion: 'success' }
  ]) {
    let writes = 0, inferred = false;
    const api = withFailure((endpoint, method) => {
      if (method === 'POST') writes++;
      return endpoint === '/pulls/7' ? pr() : [];
    }, SHA, [red, latest]);
    assert.throws(() => currentFailure(api, REPOSITORY, SHA));
    assert.throws(() => { claim(api, REPOSITORY, 7, SHA, 'manual'); inferred = true; });
    assert.equal(inferred, false); assert.equal(writes, 0);
  }
  const capped = withFailure(() => [], SHA, Array.from({ length: 100 }, () => red));
  assert.throws(() => currentFailure(capped, REPOSITORY, SHA), /incomplete/);
});

test('verification observation is bounded and missing exact-head runs remain blocked without real sleeps', async () => {
  let waited = 0, dispatched = 0;
  const api = (endpoint, method) => {
    if (endpoint === '/pulls/7') return pr();
    if (method === 'POST') { dispatched++; return null; }
    return { workflow_runs: [{ id: 1, head_sha: 'b'.repeat(40), event: 'workflow_dispatch' }] };
  };
  const result = await dispatchVerification(api, REPOSITORY, 7, SHA,
    { attempts: 2, wait: async () => { waited++; } });
  assert.equal(dispatched, 2); assert.equal(waited, 2);
  assert.deepEqual(result.map(item => item.state), ['verification_blocked', 'verification_blocked']);
  assert.deepEqual(result.map(item => item.run), [null, null]);
});

test('workflow credential gate dominates repair checkout, installation and publication jobs', () => {
  const source = fs.readFileSync(path.join(__dirname, '../workflows/pr-autofix-worker.yml'), 'utf8');
  const parsed = spawnSync('ruby', ['-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false))'],
    { input: source, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  const workflow = JSON.parse(parsed.stdout);
  assert.match(workflow.jobs.repair.if, /readiness == 'prepared'/);
  assert.match(workflow.jobs.publish.if, /readiness == 'prepared'/);
  assert.equal(workflow.jobs.automerge.if, false);
  assert.equal(workflow.jobs.validate.permissions.actions, 'read');
  assert.equal(workflow.concurrency.group, 'pr-autofix-worker-${{ inputs.pr_number }}');
  const ready = workflow.jobs.validate.steps.find(step => step.id === 'ready');
  assert.match(ready.run, /export REPAIR_CREDENTIALS_AVAILABLE=false/);
  assert.equal(workflow.jobs.validate.steps.some(step => step.with?.path === 'repair' || step.run?.includes('npm install')), false);
  for (const job of Object.values(workflow.jobs)) {
    for (const step of job.steps) if (step.uses?.startsWith('actions/checkout@')) assert.equal(step.with['persist-credentials'], false);
  }
  const inference = workflow.jobs.repair.steps.find(step => step.id === 'inference');
  assert.ok(inference.run.indexOf('pr-repair-safety.cjs failure') < inference.run.indexOf('codex exec'));
  assert.ok(inference.run.indexOf('unset REPAIR_METADATA_TOKEN') < inference.run.indexOf('codex exec'));
});

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

test('real detached Git publishes HEAD to the explicit existing branch', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const api = withFailure(() => pr(f.git(f.remote, 'rev-parse', 'refs/heads/feature/repair')), f.expected);
  const result = publish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work });
  assert.equal(result.state, 'published_verification_pending');
  assert.notEqual(result.sha, f.expected);
  assert.equal(f.git(f.remote, 'show', 'feature/repair:src/value.txt'), 'fixed');
});

test('changed metadata or remote head prevents publication', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  assert.throws(() => publish({ api: () => pr('b'.repeat(40)), repository: REPOSITORY,
    number: 7, expected: f.expected, directory: f.work }), /trusted current-head/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
  const next = f.git(f.work, 'commit-tree', `${f.expected}^{tree}`, '-p', f.expected, '-m', 'concurrent');
  f.git(f.work, 'push', 'origin', `${next}:refs/heads/feature/repair`);
  assert.throws(() => publish({ api: withFailure(() => pr(f.expected), f.expected), repository: REPOSITORY,
    number: 7, expected: f.expected, directory: f.work }), /Remote branch changed/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), next);
});

test('green or in-progress CI blocks actual Git publication before commit or push', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  for (const status of ['completed', 'in_progress']) {
    const api = withFailure(() => pr(f.expected), f.expected, [{ id: 102, run_attempt: 2, workflow_id: 42,
      head_sha: f.expected, head_repository: { full_name: REPOSITORY }, event: 'workflow_dispatch',
      status, conclusion: status === 'completed' ? 'success' : null }]);
    assert.throws(() => publish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work }), /repair blocked/);
    assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
    assert.equal(f.git(f.work, 'rev-parse', 'HEAD'), f.expected);
  }
});

test('remote race after final metadata validation is rejected by the actual push lease', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const concurrent = f.git(f.work, 'commit-tree', `${f.expected}^{tree}`, '-p', f.expected, '-m', 'concurrent');
  let reads = 0;
  const api = withFailure(() => {
    reads++;
    if (reads === 2) f.git(f.work, 'push', 'origin', `${concurrent}:refs/heads/feature/repair`);
    return pr(f.expected);
  }, f.expected);
  assert.throws(() => publish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work }), /git failed/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), concurrent);
});

test('readiness CLI with a fake gh cannot call any API when credentials are absent', t => {
  const f = fixture(t);
  const bin = path.join(f.root, 'bin'); fs.mkdirSync(bin);
  const called = path.join(f.root, 'called');
  fs.writeFileSync(path.join(bin, 'gh'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(called)}, 'unexpected'); process.exit(91);\n`);
  fs.chmodSync(path.join(bin, 'gh'), 0o755);
  const result = spawnSync(process.execPath, [path.join(__dirname, 'pr-repair-safety.cjs'), 'readiness'], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      REPAIR_CREDENTIALS_AVAILABLE: 'false', REPAIR_WRITERS_ENABLED: 'true', GITHUB_OUTPUT: '' }
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).state, 'blocked_credentials');
  assert.equal(fs.existsSync(called), false);
});

test('NUL-safe policy rejects untracked credentials, renames, symlinks and submodules', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.work, '.env.fixture'), 'owned fixture');
  assert.throws(() => validateChanges(f.work, f.expected), /protected path/);
  fs.rmSync(path.join(f.work, '.env.fixture'));
  f.git(f.work, 'mv', 'src/value.txt', 'src/renamed.txt');
  assert.throws(() => validateChanges(f.work, f.expected), /rename/);
  f.git(f.work, 'restore', '--staged', '--worktree', '.');
  fs.symlinkSync('value.txt', path.join(f.work, 'src/link'));
  assert.throws(() => validateChanges(f.work, f.expected), /symlink/);
  f.git(f.work, 'add', 'src/link');
  assert.throws(() => validateChanges(f.work, f.expected), /symlink/);
  f.git(f.work, 'restore', '--staged', 'src/link'); fs.rmSync(path.join(f.work, 'src/link'));
  f.git(f.work, 'update-index', '--add', '--cacheinfo', `160000,${f.expected},src/submodule`);
  assert.throws(() => validateChanges(f.work, f.expected), /Submodule/);
});

test('dispatcher refreshes metadata and never dispatches a stale, draft or fork candidate', () => {
  const posts = [];
  const api = withFailure((endpoint, method, body) => {
    if (method === 'POST') { posts.push(body); return {}; }
    if (endpoint.includes('/commits/')) return [{ number: 7 }, { number: 8 }];
    const candidate = pr(); if (endpoint === '/pulls/8') candidate.draft = true;
    return candidate;
  });
  assert.deepEqual(dispatch({ api, repository: REPOSITORY, sha: SHA, event: 'pull_request' }), [7]);
  assert.equal(posts.length, 1); assert.equal(posts[0].ref, 'master');
  assert.equal(posts[0].inputs.head_sha, SHA);
});

test('explicit CI and CodeQL dispatch identify new runs at the published SHA without claiming green', async () => {
  const dispatched = new Set();
  const api = (endpoint, method, body) => {
    if (endpoint === '/pulls/7') return pr();
    const workflow = endpoint.includes('codeql.yml') ? 'codeql.yml' : 'ci.yml';
    if (method === 'POST') { assert.equal(body.ref, 'feature/repair'); dispatched.add(workflow); return null; }
    return { workflow_runs: dispatched.has(workflow) ? [{ id: workflow === 'ci.yml' ? 11 : 12, head_sha: SHA, event: 'workflow_dispatch', conclusion: 'success' }] : [] };
  };
  const evidence = await dispatchVerification(api, REPOSITORY, 7, SHA);
  assert.deepEqual([...dispatched], ['ci.yml', 'codeql.yml']);
  assert.deepEqual(evidence.map(item => item.state), ['pending', 'pending']);
});

test('watchdog proposes only current trusted PR metadata without dispatching or claiming readiness', () => {
  const { assess, render } = require('./repository-health-watchdog.cjs');
  const candidate = pr(), draft = pr(); draft.number = 8; draft.draft = true;
  const state = assess({ runs: [{ id: 1, workflow_id: 2, head_sha: SHA, event: 'pull_request', status: 'completed', conclusion: 'failure' }],
    pulls: [candidate, draft], issues: [], masterSha: 'b'.repeat(40), capped: [], repository: REPOSITORY,
    repairReadiness: 'blocked_credentials' });
  assert.deepEqual(state.repairCandidates, [{ number: 7, sha: SHA }]);
  assert.match(render(state, REPOSITORY, []).body, /blocked_credentials/);
  assert.match(render(state, REPOSITORY, []).body, /No repair is dispatched/);
});

test('fake gh subprocess rejects changed head before any publication command', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const bin = path.join(f.root, 'bin'); fs.mkdirSync(bin);
  const gh = path.join(bin, 'gh');
  fs.writeFileSync(gh, `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(pr('b'.repeat(40))))});\n`);
  fs.chmodSync(gh, 0o755);
  const result = spawnSync(process.execPath, [path.join(__dirname, 'pr-repair-safety.cjs'), 'publish', '7', f.expected, f.work], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, GITHUB_REPOSITORY: REPOSITORY, GITHUB_OUTPUT: '' }
  });
  assert.equal(result.status, 1); assert.match(result.stderr, /trusted current-head/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
});
