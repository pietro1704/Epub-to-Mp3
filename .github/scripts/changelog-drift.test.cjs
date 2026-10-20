'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } = require('node:fs');
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

const drift = workflow('changelog-drift.yml');
const comparison = drift.jobs.drift.steps.find(step => step.id === 'diff').run;

test('Dependabot comparison is informational and has no GitHub write capability', () => {
  assert.deepEqual(drift.permissions, { contents: 'read' });
  assert.equal(drift.jobs.drift.if, undefined);
  const events = drift.on ?? drift.true;
  assert.deepEqual(Object.keys(events), ['pull_request']);
  for (const path of ['web/package.json', 'python_app/**', '.github/workflows/changelog-drift.yml',
    '.github/workflows/changelog-drift-contracts.yml', '.github/scripts/changelog-drift.test.cjs']) {
    assert.ok(events.pull_request.paths.includes(path), `Missing trigger: ${path}`);
  }
  assert.equal(drift.jobs.drift['continue-on-error'], true);
  assert.equal(drift.jobs.drift.steps.find(step => step.id === 'diff')['continue-on-error'], true);
  const checkout = drift.jobs.drift.steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with['persist-credentials'], false);
  assert.ok(!drift.jobs.drift.steps.some(step => step.uses?.startsWith('actions/github-script@')));
  assert.doesNotMatch(JSON.stringify(drift), /createComment|pull_request_target|gh\s+(api|pr)|issues:\s*write/);
});

test('focused contract workflow is read only and tests its actual checked-out revision', () => {
  const contract = workflow('changelog-drift-contracts.yml');
  const events = contract.on ?? contract.true;
  assert.deepEqual(Object.keys(events).sort(), ['pull_request', 'workflow_dispatch']);
  assert.deepEqual(contract.permissions, { contents: 'read' });
  assert.deepEqual(events.pull_request.paths, (drift.on ?? drift.true).pull_request.paths.slice(-3));
  const steps = contract.jobs.contracts.steps;
  const checkout = steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, undefined);
  assert.equal(checkout.with['persist-credentials'], false);
  assert.equal(steps.find(step => step.uses?.startsWith('actions/setup-node@')).with['node-version'], '24');
  assert.equal(steps.find(step => step.uses?.startsWith('actions/setup-node@')).with['package-manager-cache'], false);
  assert.ok(steps.some(step => step.run === 'node --test .github/scripts/changelog-drift.test.cjs'));
});

function execute({ committed = 'same\n', generated = committed, brokenOutput = false, brokenSummary = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'changelog-drift-contract-'));
  try {
    const bin = join(directory, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'gh'), '#!/usr/bin/env bash\nprintf called > "$API_MARKER"\nexit 99\n', { mode: 0o755 });
    writeFileSync(join(directory, 'CHANGELOG.md'), committed);
    if (generated !== null) writeFileSync(join(directory, 'GENERATED_CHANGELOG.md'), generated);
    const output = join(directory, 'output');
    const summary = join(directory, 'summary');
    if (brokenOutput) mkdirSync(output);
    if (brokenSummary) mkdirSync(summary);
    const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', comparison], {
      cwd: directory, encoding: 'utf8', timeout: 5000,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_OUTPUT: output,
        GITHUB_STEP_SUMMARY: summary, API_MARKER: join(directory, 'api-called') },
    });
    assert.equal(result.error, undefined);
    assert.equal(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8'), committed);
    if (generated !== null) assert.equal(readFileSync(join(directory, 'GENERATED_CHANGELOG.md'), 'utf8'), generated);
    else assert.equal(existsSync(join(directory, 'GENERATED_CHANGELOG.md')), false);
    assert.equal(existsSync(join(directory, 'api-called')), false, 'Comparison must never call GitHub');
    return { ...result, output: existsSync(output) && !brokenOutput ? readFileSync(output, 'utf8') : '',
      summary: existsSync(summary) && !brokenSummary ? readFileSync(summary, 'utf8') : '' };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test('identical generated changelog records no drift and leaves both files unchanged', () => {
  const result = execute();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, 'drift=false\n');
  assert.match(result.summary, /No CHANGELOG drift/);
  assert.doesNotMatch(result.stdout, /::warning::/);
});

test('different generated changelog warns with fixed guidance and a bounded preview', () => {
  const result = execute({ committed: 'old\n'.repeat(200), generated: 'new\n'.repeat(200) });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, 'drift=true\n');
  assert.match(result.stdout, /::warning::CHANGELOG.md is out of sync/);
  assert.match(result.summary, /mise run changelog/);
  assert.ok(result.stdout.trim().split('\n').length <= 101);
  assert.doesNotMatch(result.summary, /old\n|new\n/, 'Summary guidance must not embed untrusted file contents');
});

test('missing generated output records an informational skip without creating it', () => {
  const result = execute({ generated: null });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, 'drift=skip\n');
  assert.match(result.summary, /did not produce output/);
});

test('output and summary write failures preserve their nonzero status without mutation', () => {
  for (const options of [{ brokenOutput: true }, { brokenSummary: true }]) {
    const result = execute(options);
    assert.notEqual(result.status, 0);
  }
});
