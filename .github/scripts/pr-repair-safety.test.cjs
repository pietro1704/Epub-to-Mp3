'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateChanges } = require('./pr-repair-safety.cjs');

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-repair-policy-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: directory, encoding: 'utf8',
      env: { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
        GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' } });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git('init');
  git('config', 'core.hooksPath', '/dev/null');
  fs.mkdirSync(path.join(directory, 'ios'));
  const entitlement = path.join(directory, 'ios', 'Fixture.entitlements');
  fs.writeFileSync(entitlement, '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n');
  git('add', '--', 'ios/Fixture.entitlements');
  git('commit', '-m', 'Owned policy fixture');
  const expected = git('rev-parse', 'HEAD');
  git('checkout', '--detach', expected);
  return { directory, entitlement, expected, git };
}

test('real Git repair rejects a changed signing entitlement before staging', t => {
  const f = fixture(t);
  fs.writeFileSync(f.entitlement,
    '<?xml version="1.0"?><plist version="1.0"><dict><key>fixture-only</key><true/></dict></plist>\n');
  assert.match(f.git('status', '--porcelain=v1'), /ios\/Fixture\.entitlements/);
  assert.throws(() => validateChanges(f.directory, f.expected), /protected path/);
  assert.equal(f.git('diff', '--cached', '--name-only'), '');
  assert.equal(f.git('rev-parse', 'HEAD'), f.expected);
});
