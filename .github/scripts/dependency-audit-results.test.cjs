'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

test('a missing required scanner report must fail without publishing clean findings', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-report-contract-'));
  try {
    fs.writeFileSync(path.join(directory, 'cargo-audit.json'), JSON.stringify({
      vulnerabilities: { found: false, count: 0, list: [] },
    }));
    fs.writeFileSync(path.join(directory, 'pip-audit.json'), JSON.stringify({
      dependencies: [{ name: 'example', version: '1.0', vulns: [] }],
    }));
    const result = spawnSync(process.execPath, [path.join(__dirname, 'dependency-audit-results.cjs'),
      '--directory', directory], { encoding: 'utf8', timeout: 5000 });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0, 'missing npm-audit.json must not be accepted as a clean scan');
    assert.match(result.stderr, /Missing required scanner report: npm-audit\.json/);
    assert.equal(fs.existsSync(path.join(directory, 'vulnerability-findings.json')), false);
    assert.doesNotMatch(result.stdout, /findings=\[\]/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('invalid scanner JSON must fail without publishing clean findings', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-report-contract-'));
  try {
    fs.writeFileSync(path.join(directory, 'cargo-audit.json'), JSON.stringify({
      vulnerabilities: { found: false, count: 0, list: [] },
    }));
    fs.writeFileSync(path.join(directory, 'pip-audit.json'), JSON.stringify({ dependencies: [] }));
    fs.writeFileSync(path.join(directory, 'npm-audit.json'), '{');
    const result = spawnSync(process.execPath, [path.join(__dirname, 'dependency-audit-results.cjs'),
      '--directory', directory], { encoding: 'utf8', timeout: 5000 });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0, 'invalid npm-audit.json must not be accepted as a clean scan');
    assert.match(result.stderr, /Invalid scanner JSON: npm-audit\.json/);
    assert.equal(fs.existsSync(path.join(directory, 'vulnerability-findings.json')), false);
    assert.doesNotMatch(result.stdout, /findings=\[\]/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
