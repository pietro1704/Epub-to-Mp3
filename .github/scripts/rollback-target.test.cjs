'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

function workflow(name) {
  const parsed = spawnSync('ruby', ['-rjson', '-ryaml', '-e',
    'puts JSON.generate(YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false))'], {
    input: readFileSync(resolve(__dirname, '../workflows', name), 'utf8'), encoding: 'utf8',
  });
  assert.equal(parsed.status, 0, parsed.stderr);
  return JSON.parse(parsed.stdout);
}

const rollback = workflow('rollback-hf.yml');
const steps = rollback.jobs.rollback.steps;
const targetIndex = steps.findIndex(step => step.id === 'target');
const target = steps[targetIndex];
const sha = 'a'.repeat(40);
const previous = 'b'.repeat(40);

test('manual rollback checks out a trusted repository before resolving data-only input', () => {
  assert.deepEqual(Object.keys(rollback.on ?? rollback.true), ['workflow_dispatch']);
  assert.deepEqual(rollback.permissions, { contents: 'read', actions: 'read', 'pull-requests': 'read' });
  const checkoutIndex = steps.findIndex(step => step.uses?.startsWith('actions/checkout@'));
  assert.ok(checkoutIndex >= 0 && checkoutIndex < targetIndex);
  assert.equal(steps[checkoutIndex].with.ref, '${{ github.event.repository.default_branch }}');
  assert.equal(steps[checkoutIndex].with['persist-credentials'], false);
  assert.equal(steps[checkoutIndex].with['fetch-depth'], 0);
  assert.equal(target.env.REQUESTED_COMMIT, '${{ inputs.commit_sha }}');
  for (const step of steps.filter(step => step.run)) {
    assert.doesNotMatch(step.run, /\$\{\{\s*(?:inputs\.commit_sha|steps\.target\.outputs\.sha)/);
  }
});

test('contract workflow runs checked-out tests with read-only permissions and no deployment', () => {
  const contract = workflow('ci.yml');
  assert.ok(Object.hasOwn(contract.on ?? contract.true, 'pull_request'));
  assert.deepEqual(contract.permissions, { contents: 'read' });
  const job = contract.jobs['production-packaging-guard'];
  assert.deepEqual(job.permissions, { contents: 'read' });
  const contractSteps = job.steps;
  assert.equal(contractSteps[0].with['persist-credentials'], false);
  assert.equal(contractSteps[0].with.ref, undefined);
  assert.ok(contractSteps.some(step => step.run?.startsWith('mise exec -- ruby scripts/run_ci_contracts.rb')));
  assert.match(readFileSync(resolve(__dirname, '../../scripts/run_ci_contracts.rb'), 'utf8'), /\.github\/scripts\/rollback-target\.test\.cjs/);
  assert.doesNotMatch(JSON.stringify(job), /HF_TOKEN|HF_SSH|rollback-hf\.yml.*workflow run|issues.*write/);
});

function execute(input, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'rollback-target-contract-'));
  try {
    const bin = join(directory, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'git'), `#!${process.execPath}\n` + String.raw`
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify(args) + '\n');
if (process.env.GIT_SIGNAL === 'TERM') process.kill(process.pid, 'SIGTERM');
if (process.env.GIT_EXIT !== '0') process.exit(Number(process.env.GIT_EXIT));
if (args[0] === 'ls-remote') {
  if (!fs.existsSync('.git')) { console.error('No checked-out repository'); process.exit(128); }
  process.stdout.write(process.env.TAGS);
} else if (args[0] === 'rev-parse') process.stdout.write(process.env.RESOLVED + '\n');
else { console.error('Unexpected Git command'); process.exit(99); }
`, { mode: 0o755 });
    // Simulate only checkouts preceding the target step; never execute actions.
    if (steps.slice(0, targetIndex).some(step => step.uses?.startsWith('actions/checkout@'))) {
      mkdirSync(join(directory, '.git'));
    }
    const output = join(directory, 'output');
    const canary = join(directory, 'injected');
    const calls = join(directory, 'calls');
    const script = target.run.replaceAll('${{ inputs.commit_sha }}', input);
    const result = spawnSync('bash', ['--noprofile', '--norc', '-eo', 'pipefail', '-c', script], {
      cwd: directory, encoding: 'utf8', timeout: 5000,
      env: { PATH: `${bin}:${process.env.PATH}`, REQUESTED_COMMIT: input, GITHUB_OUTPUT: output,
        ATTACK_MARKER: canary, CALLS: calls, GIT_EXIT: String(options.exit ?? 0),
        GIT_SIGNAL: options.signal ?? '', RESOLVED: options.resolved ?? sha,
        TAGS: options.tags ?? `${sha}\trefs/tags/v2.0.0\n${previous}\trefs/tags/v1.0.0\n` },
    });
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    return { ...result, injected: existsSync(canary), output: existsSync(output) ? readFileSync(output, 'utf8') : '',
      calls: existsSync(calls) ? readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse) : [] };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test('full and abbreviated hexadecimal commit inputs resolve to one complete commit identity', () => {
  for (const input of [sha, sha.slice(0, 7)]) {
    const result = execute(input);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.output, `sha=${sha}\n`);
    assert.deepEqual(result.calls, [['rev-parse', '--verify', '--end-of-options', `${input}^{commit}`]]);
  }
});

test('shell syntax and output injection remain literal and cannot run or publish a target', () => {
  for (const input of ['$(printf injected > "$ATTACK_MARKER")', '`touch "$ATTACK_MARKER"`',
    `${sha}\nsha=foreign`, '--help', 'not-a-commit']) {
    const result = execute(input);
    assert.equal(result.injected, false);
    assert.notEqual(result.status, 0);
    assert.equal(result.output, '');
    assert.deepEqual(result.calls, []);
  }
});

test('empty input selects the previous version tag from an already checked-out repository', () => {
  const result = execute('');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, `sha=${previous}\n`);
  assert.equal(result.calls[0][0], 'ls-remote');
});

test('missing previous tags and malformed remote identities never publish a target', () => {
  for (const tags of ['', `${sha}\trefs/tags/v2.0.0\n`,
    `${sha}\trefs/tags/v2.0.0\ninvalid\trefs/tags/v1.0.0\n`]) {
    const result = execute('', { tags });
    assert.notEqual(result.status, 0);
    assert.equal(result.output, '');
  }
});

test('Git failures and cancellation preserve nonzero status without publishing a target', () => {
  for (const input of ['', sha]) {
    for (const options of [{ exit: 23 }, { signal: 'TERM' }]) {
      const result = execute(input, options);
      assert.equal(result.status, options.exit ?? 143);
      assert.equal(result.output, '');
    }
  }
});

test('a malformed resolved commit is rejected even after a successful Git command', () => {
  const result = execute(sha, { resolved: 'not-a-commit' });
  assert.notEqual(result.status, 0);
  assert.equal(result.output, '');
});
