'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

function validReports() {
  return {
    'cargo-audit.json': {
      database: { 'advisory-count': 1, 'last-commit': null, 'last-updated': null },
      lockfile: { 'dependency-count': 1 },
      settings: { target_arch: [], target_os: [], severity: null, ignore: [], informational_warnings: [] },
      vulnerabilities: { found: false, count: 0, list: [] },
      warnings: {},
    },
    'pip-audit.json': { dependencies: [{ name: 'example', version: '1.0', vulns: [] }], fixes: [] },
    'npm-audit.json': {
      auditReportVersion: 2,
      vulnerabilities: {},
      metadata: { vulnerabilities: { info: 0, low: 0, moderate: 0, high: 0, critical: 0, total: 0 } },
    },
    'scanner-statuses.json': { cargoInstall: 0, cargoAudit: 0, pipInstall: 0, pipAudit: 0, npmAudit: 0 },
  };
}

function withReports(overrides, check) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-report-contract-'));
  try {
    for (const [name, data] of Object.entries({ ...validReports(), ...overrides })) {
      if (data === undefined) continue;
      fs.writeFileSync(path.join(directory, name), typeof data === 'string' ? data : JSON.stringify(data));
    }
    const result = spawnSync(process.execPath, [path.join(__dirname, 'dependency-audit-results.cjs'),
      '--directory', directory], { encoding: 'utf8', timeout: 5000 });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    check(result, directory);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function assertRejected(result, directory, cause) {
  assert.notEqual(result.status, 0, `${cause} must not be accepted as a clean scan`);
  assert.match(result.stderr, cause);
  assert.equal(fs.existsSync(path.join(directory, 'vulnerability-findings.json')), false);
  assert.doesNotMatch(result.stdout, /findings=/);
}

test('complete valid clean scanner reports publish clean findings', () => {
  withReports({}, (result, directory) => {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, '');
    assert.equal(result.stdout, 'findings=[]\n');
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'vulnerability-findings.json'), 'utf8')), []);
  });
});

test('valid vulnerability reports retain all scanner payloads', () => {
  const reports = {
    'cargo-audit.json': { ...validReports()['cargo-audit.json'], vulnerabilities: { found: true, count: 1, list: [{
      advisory: { id: 'RUSTSEC-2099-0001' }, package: { name: 'example', version: '1.0.0' },
    }] } },
    'pip-audit.json': { dependencies: [{ name: 'example', version: '1.0',
      vulns: [{ id: 'PYSEC-2099-1', fix_versions: ['1.1'] }] }], fixes: [] },
    'npm-audit.json': {
      auditReportVersion: 2,
      vulnerabilities: { example: { name: 'example', severity: 'moderate', via: ['fixture'] } },
      metadata: { vulnerabilities: { info: 0, low: 0, moderate: 1, high: 0, critical: 0, total: 1 } },
    },
    'scanner-statuses.json': { cargoInstall: 0, cargoAudit: 1, pipInstall: 0, pipAudit: 1, npmAudit: 1 },
  };
  withReports(reports, (result, directory) => {
    assert.equal(result.status, 0, result.stderr);
    const expected = ['cargo-audit.json', 'pip-audit.json', 'npm-audit.json']
      .map(source => ({ source, data: reports[source] }));
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'vulnerability-findings.json'), 'utf8')), expected);
    assert.equal(result.stdout, `findings=${JSON.stringify(expected)}\n`);
  });
});

test('a missing required scanner report must fail without publishing clean findings', () => {
  withReports({ 'npm-audit.json': undefined }, (result, directory) => {
    assertRejected(result, directory, /Missing required scanner report: npm-audit\.json/);
  });
});

test('invalid scanner JSON must fail without publishing clean findings', () => {
  withReports({ 'npm-audit.json': '{' }, (result, directory) => {
    assertRejected(result, directory, /Invalid scanner JSON: npm-audit\.json/);
  });
});

test('an npm report without vulnerability metadata must fail instead of defaulting to zero', () => {
  const report = { ...validReports()['npm-audit.json'], metadata: {} };
  withReports({ 'npm-audit.json': report }, (result, directory) => {
    assertRejected(result, directory, /Invalid scanner schema: npm-audit\.json/);
  });
});

test('a failed cargo audit command must not publish clean findings from otherwise valid reports', () => {
  const statuses = { ...validReports()['scanner-statuses.json'], cargoAudit: 2 };
  withReports({ 'scanner-statuses.json': statuses }, (result, directory) => {
    assertRejected(result, directory, /Unsuccessful scanner command: cargoAudit/);
  });
});

for (const [label, value, cause] of [
  ['missing', undefined, /Missing required scanner report: scanner-statuses\.json/],
  ['invalid JSON', '{', /Invalid scanner JSON: scanner-statuses\.json/],
  ['non-object', [], /Invalid scanner schema: scanner-statuses\.json/],
  ['missing fields', { cargoInstall: 0 }, /Invalid scanner schema: scanner-statuses\.json/],
  ['string code', { ...validReports()['scanner-statuses.json'], cargoAudit: '0' }, /Invalid scanner schema: scanner-statuses\.json/],
  ['fractional code', { ...validReports()['scanner-statuses.json'], cargoAudit: 0.5 }, /Invalid scanner schema: scanner-statuses\.json/],
  ['negative code', { ...validReports()['scanner-statuses.json'], cargoAudit: -1 }, /Invalid scanner schema: scanner-statuses\.json/],
  ['unexpected field', { ...validReports()['scanner-statuses.json'], unknown: 0 }, /Invalid scanner schema: scanner-statuses\.json/],
]) {
  test(`scanner statuses reject ${label} without findings`, () => {
    withReports({ 'scanner-statuses.json': value }, (result, directory) => {
      assertRejected(result, directory, cause);
    });
  });
}

for (const command of ['cargoInstall', 'pipInstall']) {
  test(`${command} failure is rejected independently of clean audit reports`, () => {
    const statuses = { ...validReports()['scanner-statuses.json'], [command]: 1 };
    withReports({ 'scanner-statuses.json': statuses }, (result, directory) => {
      assertRejected(result, directory, new RegExp(`Unsuccessful scanner command: ${command}`));
    });
  });
}

for (const [command, status] of [['cargoAudit', 130], ['pipAudit', 143], ['npmAudit', 127], ['pipAudit', 255]]) {
  test(`${command} exit ${status} is rejected without findings`, () => {
    const statuses = { ...validReports()['scanner-statuses.json'], [command]: status };
    withReports({ 'scanner-statuses.json': statuses }, (result, directory) => {
      assertRejected(result, directory, new RegExp(`Unsuccessful scanner command: ${command}`));
      assert.equal(result.status, status === 130 || status === 143 ? status : 1);
    });
  });
}

function npmReport(severity) {
  const counts = { info: 0, low: 0, moderate: 0, high: 0, critical: 0, total: 1, [severity]: 1 };
  return {
    auditReportVersion: 2,
    vulnerabilities: { example: { name: 'example', severity, via: ['fixture'] } },
    metadata: { vulnerabilities: counts },
  };
}

for (const [severity, status] of [['low', 0], ['moderate', 1]]) {
  test(`npm ${severity} findings with exit ${status} preserve their payload`, () => {
    const report = npmReport(severity);
    const statuses = { ...validReports()['scanner-statuses.json'], npmAudit: status };
    withReports({ 'npm-audit.json': report, 'scanner-statuses.json': statuses }, (result, directory) => {
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'vulnerability-findings.json'), 'utf8')),
        [{ source: 'npm-audit.json', data: report }]);
    });
  });
}

for (const command of ['cargoAudit', 'pipAudit', 'npmAudit']) {
  test(`${command} nonzero exit cannot contradict a clean report`, () => {
    const statuses = { ...validReports()['scanner-statuses.json'], [command]: 1 };
    withReports({ 'scanner-statuses.json': statuses }, (result, directory) => {
      assertRejected(result, directory, new RegExp(`Unsuccessful scanner command: ${command}`));
    });
  });
}

test('npm moderate findings cannot have a successful scanner exit below the configured threshold', () => {
  withReports({ 'npm-audit.json': npmReport('moderate') }, (result, directory) => {
    assertRejected(result, directory, /Unsuccessful scanner command: npmAudit/);
  });
});

test('an embedded cargo scanner error must not be accepted as a clean report', () => {
  const report = { ...validReports()['cargo-audit.json'], error: { message: 'private fixture error detail' } };
  withReports({ 'cargo-audit.json': report }, (result, directory) => {
    assertRejected(result, directory, /Scanner reported an error: cargo-audit\.json/);
    assert.doesNotMatch(result.stderr, /private fixture error detail/);
  });
});

test('a skipped pip dependency must not be accepted as a complete clean audit', () => {
  const report = {
    dependencies: [
      { name: 'example', version: '1.0', vulns: [] },
      { name: 'unresolved-example', skip_reason: 'private fixture skip detail' },
    ],
    fixes: [],
  };
  withReports({ 'pip-audit.json': report }, (result, directory) => {
    assertRejected(result, directory, /Incomplete scanner report: pip-audit\.json/);
    assert.doesNotMatch(result.stderr, /private fixture skip detail/);
  });
});

test('a cargo report without vulnerability results must not default to a clean audit', () => {
  const report = { ...validReports()['cargo-audit.json'] };
  delete report.vulnerabilities;
  withReports({ 'cargo-audit.json': report }, (result, directory) => {
    assertRejected(result, directory, /Invalid scanner schema: cargo-audit\.json/);
  });
});

test('a pip report without dependency results must not default to a clean audit', () => {
  withReports({ 'pip-audit.json': { fixes: [] } }, (result, directory) => {
    assertRejected(result, directory, /Invalid scanner schema: pip-audit\.json/);
  });
});

for (const vulnerable of [false, true]) {
  test(`legacy pip dependency arrays preserve ${vulnerable ? 'vulnerable' : 'clean'} results`, () => {
    const report = [{ name: 'example', version: '1.0', vulns: vulnerable ? [{ id: 'PYSEC-2099-1' }] : [] }];
    const statuses = { ...validReports()['scanner-statuses.json'], pipAudit: Number(vulnerable) };
    withReports({ 'pip-audit.json': report, 'scanner-statuses.json': statuses }, (result, directory) => {
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'vulnerability-findings.json'), 'utf8')),
        vulnerable ? [{ source: 'pip-audit.json', data: report }] : []);
    });
  });
}

for (const report of [[], { dependencies: [] }]) {
  test(`empty pip dependency ${Array.isArray(report) ? 'legacy array' : 'object'} is valid`, () => {
    withReports({ 'pip-audit.json': report }, result => {
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, 'findings=[]\n');
    });
  });
}

const pipEntry = { name: 'example', version: '1.0', vulns: [] };
for (const [label, report] of [
  ['null container', null], ['string container', '"invalid"'], ['non-array dependencies', { dependencies: {} }],
  ...[null, [], 'invalid', { version: '1.0', vulns: [] }, { ...pipEntry, name: 1 },
    { ...pipEntry, name: '' }, { name: 'example', vulns: [] }, { ...pipEntry, version: 1 },
    { ...pipEntry, version: '' }, { name: 'example', version: '1.0' }, { ...pipEntry, vulns: {} }]
    .map((entry, index) => [`invalid entry ${index}`, { dependencies: [entry] }]),
]) {
  test(`pip schema rejects ${label}`, () => {
    withReports({ 'pip-audit.json': report }, (result, directory) => {
      assertRejected(result, directory, /Invalid scanner schema: pip-audit\.json/);
    });
  });
}

for (const entry of [{ name: 'example', skip_reason: null }, { ...pipEntry, skip_reason: '' }]) {
  test(`pip skip marker takes precedence with ${Object.hasOwn(entry, 'vulns') ? 'complete' : 'incomplete'} fields`, () => {
    withReports({ 'pip-audit.json': { dependencies: [entry] } }, (result, directory) => {
      assertRejected(result, directory, /Incomplete scanner report: pip-audit\.json/);
    });
  });
}

for (const [label, vulnerabilities] of [
  ['null results', null], ['array results', []], ['non-boolean found', { found: 0, count: 0, list: [] }],
  ...[-1, 0.5, '0'].map(count => [`invalid count ${JSON.stringify(count)}`, { found: false, count, list: [] }]),
  ['non-array list', { found: false, count: 0, list: {} }],
  ['count mismatch', { found: true, count: 1, list: [] }],
  ['found mismatch', { found: true, count: 0, list: [] }],
]) {
  test(`cargo schema rejects ${label}`, () => {
    const report = { ...validReports()['cargo-audit.json'], vulnerabilities };
    withReports({ 'cargo-audit.json': report }, (result, directory) => {
      assertRejected(result, directory, /Invalid scanner schema: cargo-audit\.json/);
    });
  });
}

for (const [label, counts] of [
  ['missing severity count', { total: 0 }],
  ...[-1, 0.5, '0'].map(low => [`invalid severity count ${JSON.stringify(low)}`,
    { ...validReports()['npm-audit.json'].metadata.vulnerabilities, low }]),
  ['inconsistent total', { ...validReports()['npm-audit.json'].metadata.vulnerabilities, total: 1 }],
]) {
  test(`npm schema rejects ${label}`, () => {
    const report = { ...validReports()['npm-audit.json'], metadata: { vulnerabilities: counts } };
    withReports({ 'npm-audit.json': report }, (result, directory) => {
      assertRejected(result, directory, /Invalid scanner schema: npm-audit\.json/);
    });
  });
}

test('npm findings require the vulnerability payload instead of metadata alone', () => {
  const report = npmReport('moderate');
  delete report.vulnerabilities;
  const statuses = { ...validReports()['scanner-statuses.json'], npmAudit: 1 };
  withReports({ 'npm-audit.json': report, 'scanner-statuses.json': statuses }, (result, directory) => {
    assertRejected(result, directory, /Invalid scanner schema: npm-audit\.json/);
  });
});

function scannerWorkflowSteps() {
  const source = fs.readFileSync(path.join(__dirname, '../workflows/dependency-vulnerability-remediation.yml'), 'utf8');
  const scan = source.split('\n  remediate:')[0];
  const steps = scan.split(/^      - /m).slice(1).flatMap(block => {
    const id = block.match(/^        id: (cargo|pip|npm|result)\s*$/m)?.[1];
    if (!id) return [];
    const lines = block.split('\n');
    const start = lines.findIndex(line => line.startsWith('        run: '));
    assert.notEqual(start, -1, `workflow step ${id} must have an executable run block`);
    const value = lines[start].slice('        run: '.length);
    const script = value === '|'
      ? lines.slice(start + 1).filter((line, index, rest) =>
        line.startsWith('          ') && rest.slice(0, index).every(previous => previous === '' || previous.startsWith('          ')))
        .map(line => line.slice(10)).join('\n')
      : value;
    assert.ok(script.trim(), `workflow step ${id} must not be empty`);
    return [{ id, script, cwd: block.match(/^        working-directory: (\S+)\s*$/m)?.[1] ?? '.',
      continueOnError: /^        continue-on-error: true\s*$/m.test(block) }];
  });
  assert.ok(JSON.stringify(steps.map(step => step.id)) === JSON.stringify(['cargo', 'pip', 'npm', 'result'])
    || JSON.stringify(steps.map(step => step.id)) === JSON.stringify(['result']),
  'scanner workflow must expose the legacy four steps or one consolidated result step');
  return steps;
}

function withScannerWorkflow(options, check) {
  if (typeof options === 'number') options = { statuses: { cargoInstall: options } };
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-workflow-contract-'));
  try {
    const bin = path.join(directory, 'bin');
    const ledger = path.join(directory, 'calls.jsonl');
    const githubOutput = path.join(directory, 'github-output');
    const runnerTemp = path.join(directory, 'runner-temp');
    fs.mkdirSync(bin);
    fs.mkdirSync(runnerTemp);
    fs.mkdirSync(path.join(directory, 'web'));
    fs.mkdirSync(path.join(directory, '.github/scripts'), { recursive: true });
    fs.copyFileSync(path.join(__dirname, 'dependency-audit-results.cjs'),
      path.join(directory, '.github/scripts/dependency-audit-results.cjs'));
    fs.writeFileSync(githubOutput, '');
    if (options.staleReports) {
      for (const [name, report] of Object.entries(validReports())) {
        fs.writeFileSync(path.join(directory, name), JSON.stringify(report));
      }
    }
    const shim = `#!${process.execPath}
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
let operation;
if (command === 'cargo' && args[0] === 'install') operation = 'cargoInstall';
else if (command === 'cargo' && args[0] === 'audit') operation = 'cargoAudit';
else if (command === 'python3' && args.slice(0, 3).join(' ') === '-m pip install') operation = 'pipInstall';
else if (command === 'pip-audit') operation = 'pipAudit';
else if (command === 'npm' && args[0] === 'audit') operation = 'npmAudit';
else if (command === 'python3' && ['-', '-c'].includes(args[0])) {
  const result = spawnSync('/usr/bin/python3', args, { stdio: 'inherit' });
  if (result.error || result.signal) process.exit(98);
  process.exit(result.status);
} else { console.error('Unexpected fixture command'); process.exit(97); }
fs.appendFileSync(process.env.FIXTURE_LEDGER, JSON.stringify({ operation, args }) + '\\n');
const status = JSON.parse(process.env.FIXTURE_STATUSES)[operation];
if (operation.endsWith('Install')) process.exit(status);
const names = { cargoAudit: 'cargo-audit.json', pipAudit: 'pip-audit.json', npmAudit: 'npm-audit.json' };
const report = JSON.parse(process.env.FIXTURE_REPORTS)[names[operation]];
if (report !== undefined) console.log(typeof report === 'string' ? report : JSON.stringify(report));
process.exit(status);
`;
    for (const name of ['cargo', 'python3', 'pip-audit', 'npm']) {
      fs.writeFileSync(path.join(bin, name), shim, { mode: 0o755 });
    }
    const environment = { ...process.env,
      PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH}`,
      FIXTURE_LEDGER: ledger, FIXTURE_REPORTS: JSON.stringify({ ...validReports(), ...options.reports }),
      FIXTURE_STATUSES: JSON.stringify({ ...validReports()['scanner-statuses.json'], ...options.statuses }),
      GITHUB_OUTPUT: githubOutput,
      RUNNER_TEMP: runnerTemp, GITHUB_WORKSPACE: directory, GH_TOKEN: '', GITHUB_TOKEN: '' };
    let status = 0;
    let stderr = '';
    for (const step of scannerWorkflowSteps()) {
      const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-eo', 'pipefail', '-c', step.script],
        { cwd: path.join(directory, step.cwd), env: environment, encoding: 'utf8', timeout: 10000 });
      assert.ifError(result.error);
      assert.equal(result.signal, null, result.stderr);
      stderr += result.stderr;
      status = result.status;
      if (status !== 0 && !step.continueOnError) break;
    }
    check({ status, calls: fs.readFileSync(ledger, 'utf8').trim().split('\n').map(line => JSON.parse(line).operation),
      output: fs.readFileSync(githubOutput, 'utf8'), stderr, directory, runnerTemp });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test('real scanner workflow shell publishes clean findings when all fake scanners succeed', () => {
  withScannerWorkflow(0, ({ status, calls, output }) => {
    assert.equal(status, 0);
    assert.deepEqual(calls, ['cargoInstall', 'cargoAudit', 'pipInstall', 'pipAudit', 'npmAudit']);
    assert.equal(output, 'findings=[]\n');
  });
});

test('real scanner workflow stops after installation failure without later scanners or findings', () => {
  withScannerWorkflow(23, ({ status, calls, output, directory }) => {
    assert.deepEqual(calls, ['cargoInstall'],
      `installation failure must prevent every later scanner; observed ${JSON.stringify({ status, calls, output })}`);
    assert.equal(status, 23, 'installation failure must preserve the original command status');
    assert.equal(output, '');
    assert.equal(fs.existsSync(path.join(directory, 'vulnerability-findings.json')), false);
  });
});

test('real scanner workflow preserves valid findings from all audit exit-one results', () => {
  const reports = {
    'cargo-audit.json': { ...validReports()['cargo-audit.json'],
      vulnerabilities: { found: true, count: 1, list: [{ advisory: { id: 'RUSTSEC-2099-0001' } }] } },
    'pip-audit.json': { dependencies: [{ name: 'example', version: '1.0', vulns: [{ id: 'PYSEC-2099-1' }] }] },
    'npm-audit.json': npmReport('moderate'),
  };
  withScannerWorkflow({ reports, statuses: { cargoAudit: 1, pipAudit: 1, npmAudit: 1 } }, ({ status, output, calls }) => {
    assert.equal(status, 0);
    assert.equal(calls.length, 5);
    assert.deepEqual(JSON.parse(output.slice('findings='.length)),
      Object.entries(reports).map(([source, data]) => ({ source, data })));
  });
});

test('real scanner workflow retains low npm findings with audit exit zero', () => {
  const report = npmReport('low');
  withScannerWorkflow({ reports: { 'npm-audit.json': report } }, ({ status, output }) => {
    assert.equal(status, 0);
    assert.deepEqual(JSON.parse(output.slice('findings='.length)), [{ source: 'npm-audit.json', data: report }]);
  });
});

const scannerOrder = ['cargoInstall', 'cargoAudit', 'pipInstall', 'pipAudit', 'npmAudit'];
function assertNoWorkflowFindings(directory) {
  assert.equal(fs.readdirSync(directory, { recursive: true })
    .some(name => path.basename(name) === 'vulnerability-findings.json'), false);
}

for (const [operation, exit] of [
  ['pipInstall', 23], ['cargoInstall', 130], ['pipInstall', 143],
  ...['cargoAudit', 'pipAudit', 'npmAudit'].flatMap(operation => [2, 130, 143].map(exit => [operation, exit])),
]) {
  test(`real scanner workflow stops at ${operation} exit ${exit}`, () => {
    withScannerWorkflow({ statuses: { [operation]: exit } }, ({ status, calls, output, directory }) => {
      assert.equal(status, exit);
      assert.deepEqual(calls, scannerOrder.slice(0, scannerOrder.indexOf(operation) + 1));
      assert.equal(output, '');
      assertNoWorkflowFindings(directory);
    });
  });
}

for (const [label, reports, cause] of [
  ['malformed JSON', { 'npm-audit.json': '{' }, /Invalid scanner JSON: npm-audit\.json/],
  ['missing report output', { 'npm-audit.json': undefined }, /Invalid scanner JSON: npm-audit\.json/],
  ['embedded scanner error', { 'cargo-audit.json': { error: 'private fixture detail' } }, /Scanner reported an error: cargo-audit\.json/],
  ['skipped dependency', { 'pip-audit.json': { dependencies: [{ name: 'example', skip_reason: 'private fixture detail' }] } },
    /Incomplete scanner report: pip-audit\.json/],
]) {
  test(`real scanner workflow rejects ${label} without publishing findings`, () => {
    withScannerWorkflow({ reports }, ({ status, calls, output, stderr, directory }) => {
      assert.equal(status, 1);
      assert.deepEqual(calls, scannerOrder);
      assert.equal(output, '');
      assert.match(stderr, cause);
      assert.doesNotMatch(stderr, /private fixture detail/);
      assertNoWorkflowFindings(directory);
    });
  });
}

test('real scanner workflow cannot reuse clean reports from the checkout', () => {
  withScannerWorkflow({ staleReports: true, reports: { 'npm-audit.json': '{' } },
    ({ status, output, stderr, directory, runnerTemp }) => {
      assert.equal(status, 1);
      assert.equal(output, '');
      assert.match(stderr, /Invalid scanner JSON: npm-audit\.json/);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'npm-audit.json'), 'utf8')),
        validReports()['npm-audit.json']);
      const reportDirectories = fs.readdirSync(runnerTemp);
      assert.equal(reportDirectories.length, 1);
      assert.equal(fs.readFileSync(path.join(runnerTemp, reportDirectories[0], 'npm-audit.json'), 'utf8'), '{\n');
      assert.equal(fs.existsSync(path.join(runnerTemp, reportDirectories[0], 'vulnerability-findings.json')), false);
    });
});
