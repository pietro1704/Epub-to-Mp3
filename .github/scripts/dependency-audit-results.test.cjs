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
