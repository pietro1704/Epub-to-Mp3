'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validate, readiness, attempted, claim, validateChanges, stageChanges, publish, currentFailure, dispatchVerification } = require('./pr-repair-safety.cjs');
const { dispatch } = require('./pr-repair-dispatch.cjs');
const { REPOSITORY, SHA, BASE_SHA, PREPARED, withFailure, pr, claimComment, authorizedPublish, fixture } = require('./pr-repair-test-fixtures.cjs');

test('readiness never simulates credentials or enables absent writers', () => {
  assert.equal(readiness({ credentials: false, writers: true }), 'blocked_credentials');
  assert.equal(readiness({ credentials: true, writers: false }), 'blocked_writers_disabled');
  assert.equal(readiness({ credentials: true, writers: true }), 'prepared');
  assert.equal(readiness({ credentials: 'true', writers: true }), 'blocked_credentials');
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
  assert.equal(claim(api, REPOSITORY, 7, SHA, '123', PREPARED).state, 'claimed');
  assert.equal(claim(api, REPOSITORY, 7, SHA, '124', PREPARED).state, 'deduplicated');
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
    { ...red, run_attempt: 2, conclusion: 'success' },
    { ...red, id: 100, run_attempt: 2, conclusion: 'success' },
    { ...red, id: 100, run_attempt: 2, status: 'in_progress', conclusion: null },
    { ...red, id: 100, run_attempt: 2, status: 'queued', conclusion: null },
    { ...red, id: 100, conclusion: 'cancelled' },
    { ...red, id: 100, run_attempt: 2, conclusion: 'failure' }
  ]) {
    let writes = 0, inferred = false;
    const api = withFailure((endpoint, method) => {
      if (method === 'POST') writes++;
      return endpoint === '/pulls/7' ? pr() : [];
    }, SHA, [red, latest]);
    assert.throws(() => currentFailure(api, REPOSITORY, SHA));
    assert.throws(() => { claim(api, REPOSITORY, 7, SHA, '123', PREPARED); inferred = true; });
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
    { ...PREPARED, attempts: 2, wait: async () => { waited++; } });
  assert.equal(dispatched, 1); assert.equal(waited, 1);
  assert.deepEqual(result.map(item => item.state), ['verification_blocked']);
  assert.deepEqual(result.map(item => item.run), [null]);
});

test('older run101 green or active blocks newer red102, including cross-ID rerun visibility', () => {
  const red = { id: 102, run_attempt: 1, workflow_id: 42, head_sha: SHA,
    head_repository: { full_name: REPOSITORY }, event: 'pull_request', status: 'completed', conclusion: 'failure' };
  for (const previous of [
    { ...red, id: 101, conclusion: 'success' },
    { ...red, id: 101, status: 'queued', conclusion: null },
    { ...red, id: 101, run_attempt: 2, conclusion: 'success' },
    { ...red, id: 101, run_attempt: 2, status: 'in_progress', conclusion: null }
  ]) {
    let writes = 0;
    const api = withFailure((endpoint, method) => {
      if (method === 'POST') writes++;
      return endpoint === '/pulls/7' ? pr() : [];
    }, SHA, [red, previous]);
    assert.throws(() => claim(api, REPOSITORY, 7, SHA, '123', PREPARED), /repair blocked/);
    assert.equal(writes, 0);
  }
  assert.equal(currentFailure(withFailure(() => [], SHA, [red, { ...red, id: 101 }]), REPOSITORY, SHA).failureRun, 102);
});

test('workflow credential gate dominates repair checkout, installation and publication jobs', () => {
  const source = fs.readFileSync(path.join(__dirname, '../workflows/pr-autofix-worker.yml'), 'utf8');
  const parsed = spawnSync('ruby', ['-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false))'],
    { input: source, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  const workflow = JSON.parse(parsed.stdout);
  assert.match(workflow.jobs.repair.if, /readiness == 'prepared'/);
  assert.match(workflow.jobs.publish.if, /readiness == 'prepared'/);
  assert.equal(workflow.jobs.automerge, undefined);
  assert.equal((workflow.on || workflow.true).workflow_dispatch.inputs.mode, undefined);
  assert.equal(/guarded_pr_merge|--merge/.test(source), false);
  assert.equal(workflow.jobs.validate.permissions.actions, 'read');
  assert.equal(workflow.concurrency.group, 'pr-autofix-worker-${{ inputs.pr_number }}');
  const ready = workflow.jobs.validate.steps.find(step => step.id === 'ready');
  assert.match(ready.run, /export REPAIR_CREDENTIALS_AVAILABLE=false/);
  assert.equal(workflow.jobs.validate.steps.some(step => step.with?.path === 'repair' || step.run?.includes('npm install')), false);
  for (const job of Object.values(workflow.jobs)) {
    for (const step of job.steps) if (step.uses?.startsWith('actions/checkout@')) assert.equal(step.with['persist-credentials'], false);
  }
  const inference = workflow.jobs.repair.steps.find(step => step.id === 'inference');
  assert.ok(inference.run.indexOf('pr-repair-guard.cjs" failure') < inference.run.indexOf('codex exec'));
  assert.ok(inference.run.indexOf('unset REPAIR_METADATA_TOKEN') < inference.run.indexOf('codex exec'));
  const install = workflow.jobs.repair.steps.find(step => step.run?.includes('npm install'));
  assert.equal(install.env, undefined);
  assert.equal(install['working-directory'], '${{ runner.temp }}');
  assert.ok(workflow.jobs.repair.steps.indexOf(install) < workflow.jobs.repair.steps.indexOf(inference));
  assert.equal(inference.run.includes('npm install'), false);
  assert.match(inference.run, /sha256sum --check --status/);
  const trust = workflow.jobs.repair.steps.find(step => step.id === 'trusted');
  assert.match(trust.run, /git -C trusted show/);
  assert.match(trust.run, /chmod 400/);
  assert.match(source, /stage-changes/);
  assert.equal(/git -C repair add --all/.test(source), false);
});

test('real detached Git publishes HEAD to the explicit existing branch', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const api = withFailure(() => pr(f.git(f.remote, 'rev-parse', 'refs/heads/feature/repair')), f.expected);
  const result = authorizedPublish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work });
  assert.equal(result.state, 'published_verification_pending');
  assert.notEqual(result.sha, f.expected);
  assert.equal(f.git(f.remote, 'show', 'feature/repair:src/value.txt'), 'fixed');
});

test('changed metadata or remote head prevents publication', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  assert.throws(() => authorizedPublish({ api: () => pr('b'.repeat(40)), repository: REPOSITORY,
    number: 7, expected: f.expected, directory: f.work }), /trusted current-head/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
  const next = f.git(f.work, 'commit-tree', `${f.expected}^{tree}`, '-p', f.expected, '-m', 'concurrent');
  f.git(f.work, 'push', 'origin', `${next}:refs/heads/feature/repair`);
  assert.throws(() => authorizedPublish({ api: withFailure(() => pr(f.expected), f.expected), repository: REPOSITORY,
    number: 7, expected: f.expected, directory: f.work }), /Remote branch changed/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), next);
});

test('green or in-progress CI blocks actual Git publication before commit or push', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  for (const status of ['completed', 'in_progress']) {
    const api = withFailure(() => pr(f.expected), f.expected, [{ id: 102, run_attempt: 2, workflow_id: 42,
      head_sha: f.expected, head_repository: { full_name: REPOSITORY }, event: 'workflow_dispatch',
      status, conclusion: status === 'completed' ? 'success' : null }]);
    assert.throws(() => authorizedPublish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work }), /repair blocked/);
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
  assert.throws(() => authorizedPublish({ api, repository: REPOSITORY, number: 7, expected: f.expected, directory: f.work }), /git failed/);
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
  assert.throws(() => validateChanges(f.work, f.expected), /Submodule|unsupported status/);
});

test('authentication files and directories are refused both untracked and staged', t => {
  const f = fixture(t);
  for (const filename of ['.netrc', '.npmrc', '.pypirc', 'auth.json', '.aws/credentials', '.azure/token.json',
    '.kube/config', '.config/gcloud/state.json', '.docker/config.json']) {
    const full = path.join(f.work, filename);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, 'owned authentication-shaped fixture; no real credential');
    assert.throws(() => validateChanges(f.work, f.expected), /protected path/);
    f.git(f.work, 'add', '--', filename);
    assert.throws(() => validateChanges(f.work, f.expected), /protected path/);
    f.git(f.work, 'restore', '--staged', '--', filename);
    fs.rmSync(full);
  }
});

test('dispatcher refreshes metadata and never dispatches a stale, draft or fork candidate', () => {
  const posts = [];
  const api = withFailure((endpoint, method, body) => {
    if (method === 'POST') { posts.push(body); return {}; }
    if (endpoint.includes('/commits/')) return [{ number: 7 }, { number: 8 }];
    const candidate = pr(); if (endpoint === '/pulls/8') candidate.draft = true;
    return candidate;
  });
  assert.deepEqual(dispatch({ api, repository: REPOSITORY, sha: SHA, event: 'pull_request', ...PREPARED }), [7]);
  assert.equal(posts.length, 1); assert.equal(posts[0].ref, 'master');
  assert.equal(posts[0].inputs.head_sha, SHA);
});

test('verification refuses missing or malformed base identity before dispatch', async () => {
  for (const base of [undefined, null, 'invalid']) {
    let writes = 0;
    const api = (endpoint, method) => {
      if (endpoint === '/pulls/7') { const candidate = pr(); candidate.base.sha = base; return candidate; }
      if (method === 'POST') writes++;
      return { workflow_runs: [] };
    };
    await assert.rejects(dispatchVerification(api, REPOSITORY, 7, SHA, PREPARED), /exact PR base/);
    assert.equal(writes, 0);
  }
});

test('only scoped PR CI dispatch identifies new runs at the published SHA without claiming green', async () => {
  const dispatched = new Set();
  const api = (endpoint, method, body) => {
    if (endpoint === '/pulls/7') return pr();
    const workflow = endpoint.includes('codeql.yml') ? 'codeql.yml' : 'ci.yml';
    if (method === 'POST') { assert.equal(body.ref, 'feature/repair'); assert.deepEqual(body.inputs, { full_validation: 'false', base_sha: BASE_SHA }); dispatched.add(workflow); return null; }
    return { workflow_runs: dispatched.has(workflow) ? [{ id: workflow === 'ci.yml' ? 11 : 12, head_sha: SHA, event: 'workflow_dispatch', conclusion: 'success' }] : [] };
  };
  const evidence = await dispatchVerification(api, REPOSITORY, 7, SHA, PREPARED);
  assert.deepEqual([...dispatched], ['ci.yml']);
  assert.deepEqual(evidence.map(item => item.state), ['pending']);
});

test('fake gh subprocess rejects changed head before any publication command', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const bin = path.join(f.root, 'bin'); fs.mkdirSync(bin);
  const gh = path.join(bin, 'gh');
  fs.writeFileSync(gh, `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(pr('b'.repeat(40))))});\n`);
  fs.chmodSync(gh, 0o755);
  const result = spawnSync(process.execPath, [path.join(__dirname, 'pr-repair-safety.cjs'), 'publish', '7', f.expected, f.work], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, GITHUB_REPOSITORY: REPOSITORY, GITHUB_OUTPUT: '',
      REPAIR_WRITERS_ENABLED: 'true', REPAIR_CREDENTIALS_AVAILABLE: 'true', GITHUB_RUN_ID: '123' }
  });
  assert.equal(result.status, 1); assert.match(result.stderr, /trusted current-head/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
});

test('real Git repair rejects a changed signing entitlement before staging', t => {
  const f = fixture(t);
  const entitlement = path.join(f.work, 'ios/Fixture.entitlements');
  fs.mkdirSync(path.dirname(entitlement), { recursive: true });
  fs.writeFileSync(entitlement, '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n');
  f.git(f.work, 'add', '--', 'ios/Fixture.entitlements');
  f.git(f.work, 'commit', '-m', 'Owned signing fixture');
  const expected = f.git(f.work, 'rev-parse', 'HEAD');
  fs.appendFileSync(entitlement, '<!-- owned change -->\n');
  assert.throws(() => validateChanges(f.work, expected), /protected path/);
  assert.equal(f.git(f.work, 'diff', '--cached', '--name-only'), '');
  assert.equal(f.git(f.work, 'rev-parse', 'HEAD'), expected);
});

test('concrete policy and deployment paths are refused untracked and staged', async t => {
  for (const filename of ['CODEOWNERS', 'SECURITY.md', '.gitattributes', '.gitignore',
    'ios/Fixture.entitlements', 'Dockerfile', 'compose.fixture.yml', 'deploy/task.sh',
    'infra/fixture.tf', 'scripts/native_job.rb', 'scripts/guard_remediation_changes.py',
    'config/mac-build-budget.json', 'scripts/mac_build_budget.rb',
    'scripts/native_simulator_session.rb', 'scripts/simulator_resource_monitor.py',
    'scripts/validated_merge.mjs', 'scripts/post_merge_validation.mjs',
    'scripts/run_ci_contracts.rb', 'scripts/check_codeql_swift_tool_scope.rb',
    'scripts/pr_gate_policy.mjs', 'scripts/mac_validate.rb']) {
    await t.test(filename, child => {
      const f = fixture(child), full = path.join(f.work, filename);
      fs.mkdirSync(path.dirname(full), { recursive: true });
      fs.writeFileSync(full, 'owned fixture\n');
      assert.throws(() => validateChanges(f.work, f.expected), /protected path/);
      f.git(f.work, 'add', '--', filename);
      assert.throws(() => stageChanges(f.work, f.expected), /protected path/);
      assert.equal(f.git(f.work, 'rev-parse', 'HEAD'), f.expected);
    });
  }
});

test('explicit literal staging allows ordinary tooling and deletion without expanding pathspecs', t => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.work, 'scripts'));
  for (const filename of ['scripts/conversion_tool.py', 'scripts/test_conversion_tool.py',
    'src/:literal[fixture].txt']) fs.writeFileSync(path.join(f.work, filename), 'owned source\n');
  fs.rmSync(path.join(f.work, 'src/value.txt'));
  const approved = stageChanges(f.work, f.expected).sort();
  assert.deepEqual(approved, ['scripts/conversion_tool.py', 'scripts/test_conversion_tool.py',
    'src/:literal[fixture].txt', 'src/value.txt'].sort());
  assert.equal(f.git(f.work, 'diff', '--cached', '--name-status').includes('D\tsrc/value.txt'), true);
});

test('newline names and renames in either direction are refused with the index unchanged', async t => {
  await t.test('newline', child => {
    const f = fixture(child);
    fs.writeFileSync(path.join(f.work, 'src/line\nbreak.txt'), 'owned fixture\n');
    assert.throws(() => stageChanges(f.work, f.expected), /protected path/);
    assert.equal(f.git(f.work, 'diff', '--cached', '--name-only'), '');
  });
  for (const protectedSource of [false, true]) await t.test(String(protectedSource), child => {
    const f = fixture(child);
    if (protectedSource) {
      fs.writeFileSync(path.join(f.work, 'SECURITY.md'), 'owned policy\n');
      f.git(f.work, 'add', '--', 'SECURITY.md');
      f.git(f.work, 'commit', '-m', 'Policy fixture');
    }
    const expected = f.git(f.work, 'rev-parse', 'HEAD');
    f.git(f.work, 'mv', protectedSource ? 'SECURITY.md' : 'src/value.txt',
      protectedSource ? 'src/policy.txt' : 'SECURITY.md');
    const before = f.git(f.work, 'diff', '--cached', '--raw');
    assert.throws(() => stageChanges(f.work, expected), /rename|protected path/);
    assert.equal(f.git(f.work, 'diff', '--cached', '--raw'), before);
  });
});

test('baseline symlink deletion and a submodule index entry are refused', async t => {
  await t.test('deleted baseline link', child => {
    const f = fixture(child);
    fs.symlinkSync('value.txt', path.join(f.work, 'src/link'));
    f.git(f.work, 'add', '--', 'src/link');
    f.git(f.work, 'commit', '-m', 'Link fixture');
    const expected = f.git(f.work, 'rev-parse', 'HEAD');
    fs.rmSync(path.join(f.work, 'src/link'));
    assert.throws(() => stageChanges(f.work, expected), /symlink/);
  });
  await t.test('gitlink', child => {
    const f = fixture(child);
    fs.mkdirSync(path.join(f.work, 'src/submodule'));
    f.git(f.work, 'update-index', '--add', '--cacheinfo', '160000,' + f.expected + ',src/submodule');
    assert.throws(() => stageChanges(f.work, f.expected), /Submodule|regular files/);
  });
});

test('publication requires current readiness and a claim from this trusted worker run', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  let calls = 0;
  for (const [writers, credentials] of [[false, true], [true, false]]) {
    assert.throws(() => publish({ api: () => { calls++; }, repository: REPOSITORY,
      number: 7, expected: f.expected, directory: f.work, writers, credentials, run: '123' }), /readiness/);
  }
  assert.equal(calls, 0);
  for (const comments of [[], [claimComment(f.expected, '124')],
    [{ ...claimComment(f.expected), user: { login: 'other', type: 'User' } }]]) {
    const api = withFailure(endpoint => endpoint === '/pulls/7' ? pr(f.expected) : comments, f.expected);
    assert.throws(() => publish({ api, repository: REPOSITORY, number: 7, expected: f.expected,
      directory: f.work, writers: true, credentials: true, run: '123' }), /claim/);
    assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
    assert.equal(f.git(f.work, 'rev-parse', 'HEAD'), f.expected);
  }
});

test('dispatcher is inert without explicit writer readiness and Git failures fail closed', t => {
  let calls = 0;
  assert.deepEqual(dispatch({ api: () => { calls++; }, repository: REPOSITORY,
    sha: SHA, event: 'pull_request' }), []);
  assert.equal(calls, 0);
  const f = fixture(t);
  assert.throws(() => validateChanges(f.root, f.expected), /git failed/);
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
});

test('all mutation CLIs refuse absent readiness before calling a fake gh', t => {
  const f = fixture(t), bin = path.join(f.root, 'bin');
  fs.mkdirSync(bin);
  const marker = path.join(f.root, 'api-called');
  fs.writeFileSync(path.join(bin, 'gh'), '#!' + process.execPath +
    '\nrequire("node:fs").writeFileSync(' + JSON.stringify(marker) + ', "unexpected");process.exit(91);\n');
  fs.chmodSync(path.join(bin, 'gh'), 0o755);
  for (const prepared of [{ writers: false, credentials: true }, { writers: true, credentials: false }]) {
    const env = { PATH: bin + path.delimiter + process.env.PATH, GITHUB_REPOSITORY: REPOSITORY,
      GITHUB_RUN_ID: '123', REPAIR_WRITERS_ENABLED: String(prepared.writers),
      REPAIR_CREDENTIALS_AVAILABLE: String(prepared.credentials), RUN_SHA: SHA, RUN_EVENT: 'pull_request' };
    for (const operation of ['claim', 'publish', 'verify']) {
      const result = spawnSync(process.execPath, [path.join(__dirname, 'pr-repair-safety.cjs'),
        operation, '7', f.expected, f.work], { env, encoding: 'utf8', timeout: 10000 });
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, /readiness blocked/);
    }
    const dispatcher = spawnSync(process.execPath, [path.join(__dirname, 'pr-repair-dispatch.cjs')],
      { env, encoding: 'utf8', timeout: 10000 });
    assert.equal(dispatcher.status, 0, dispatcher.stderr);
    assert.deepEqual(JSON.parse(dispatcher.stdout).dispatched, []);
    assert.equal(fs.existsSync(marker), false);
  }
});

test('metadata and incomplete failure evidence cannot claim an attempt', () => {
  const valid = { id: 101, run_attempt: 1, workflow_id: 42, head_sha: SHA,
    head_repository: { full_name: REPOSITORY }, event: 'pull_request', status: 'completed', conclusion: 'failure' };
  for (const runs of [[], [{ ...valid, workflow_id: 43 }], [{ ...valid, head_repository: { full_name: 'fork/repo' } }]]) {
    let writes = 0;
    const api = withFailure((endpoint, method) => {
      if (method === 'POST') writes++;
      return endpoint === '/pulls/7' ? pr() : [];
    }, SHA, runs);
    assert.throws(() => claim(api, REPOSITORY, 7, SHA, '123', PREPARED));
    assert.equal(writes, 0);
  }
  const wrongNumber = pr(); wrongNumber.number = 8;
  assert.throws(() => claim(withFailure(() => wrongNumber), REPOSITORY, 7, SHA, '123', PREPARED), /identity/);
});

test('head cancellation during verification stops further fake dispatches', async () => {
  let posts = 0;
  const api = (endpoint, method) => {
    if (endpoint === '/pulls/7') return pr(posts === 0 ? SHA : 'b'.repeat(40));
    if (method === 'POST') { posts++; return null; }
    return { workflow_runs: [] };
  };
  await assert.rejects(dispatchVerification(api, REPOSITORY, 7, SHA, PREPARED), /trusted current-head/);
  assert.equal(posts, 1);
});

test('post-staging path injection is detected before publication', t => {
  const f = fixture(t), bin = path.join(f.root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(f.work, 'src/value.txt'), 'fixed\n');
  const executable = spawnSync('which', ['git'], { encoding: 'utf8' });
  assert.equal(executable.status, 0);
  const realGit = executable.stdout.trim();
  const shim = '#!' + process.execPath + '\n' +
    'const fs=require("node:fs"), cp=require("node:child_process");\n' +
    'const args=process.argv.slice(2);\n' +
    'if(args.includes("--pathspec-file-nul"))fs.writeFileSync(' +
      JSON.stringify(path.join(f.work, 'src/injected.txt')) + ',"owned late fixture\\n");\n' +
    'const result=cp.spawnSync(' + JSON.stringify(realGit) +
      ',args,{stdio:"inherit",env:process.env});process.exit(result.status===null?90:result.status);\n';
  fs.writeFileSync(path.join(bin, 'git'), shim); fs.chmodSync(path.join(bin, 'git'), 0o755);
  const original = process.env.PATH;
  try {
    process.env.PATH = bin + path.delimiter + original;
    assert.throws(() => stageChanges(f.work, f.expected), /paths changed/);
  } finally { process.env.PATH = original; }
  assert.equal(f.git(f.work, 'diff', '--cached', '--name-only'), 'src/value.txt');
  assert.equal(f.git(f.remote, 'rev-parse', 'feature/repair'), f.expected);
});

test('verification revalidates the head after each history read before any dispatch', async t => {
  for (const changedWorkflow of ['ci.yml']) await t.test(changedWorkflow, async () => {
    const dispatched = [], active = new Set();
    let changed = false;
    const api = (endpoint, method) => {
      if (endpoint === '/pulls/7') return pr(changed ? 'b'.repeat(40) : SHA);
      const workflow = endpoint.includes('codeql.yml') ? 'codeql.yml' : 'ci.yml';
      if (method === 'POST') { dispatched.push(workflow); active.add(workflow); return null; }
      if (workflow === changedWorkflow && !active.has(workflow)) changed = true;
      return { workflow_runs: active.has(workflow) ?
        [{ id: 11, head_sha: SHA, event: 'workflow_dispatch' }] : [] };
    };
    await assert.rejects(dispatchVerification(api, REPOSITORY, 7, SHA, PREPARED), /trusted current-head/);
    assert.deepEqual(dispatched, changedWorkflow === 'ci.yml' ? [] : ['ci.yml']);
  });
});
