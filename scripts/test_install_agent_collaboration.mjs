import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { install } from './install_agent_collaboration.mjs';
const digest = value => createHash('sha256').update(value).digest('hex');
const script = path.resolve('scripts/install_agent_collaboration.mjs');
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'collaboration-installer-test-'));
  const root = path.join(base, 'repo');
  fs.mkdirSync(root);
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  return { root, base, file: (name, content, expected = null) => ({ path: name, content, expected_sha256: expected }), spec: files => ({ version: 1, mode: 'apply', root, files }) };
}

test('JSON stdin transports literal shell syntax and real newlines without execution', t => {
  const { root, file, spec } = fixture(t);
  const content = 'Quotes " \' backtick ` $(touch SHOULD_NOT_EXIST) \\n literal\nactual newline\nárvore';
  const child = spawnSync(process.execPath, [script], { input: JSON.stringify(spec([file('CLAUDE.md', content)])), encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  assert.equal(fs.readFileSync(path.join(root, 'CLAUDE.md'), 'utf8'), content);
  assert.equal(fs.existsSync('SHOULD_NOT_EXIST'), false);
});
test('plan reports exact hashes without creating files or directories', t => {
  const { root, file, spec } = fixture(t);
  const input = { ...spec([file('.agents/collaboration.json', '{}\n')]), mode: 'plan' };
  assert.equal(install(input).files[0].sha256, digest('{}\n'));
  assert.deepEqual(fs.readdirSync(root), []);
});
test('stale second target prevents all destination writes', t => {
  const { root, file, spec } = fixture(t);
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'existing');
  assert.throws(() => install(spec([file('mise.toml', 'new'), file('CLAUDE.md', 'replacement', digest('older'))])), /Stale baseline/);
  assert.equal(fs.existsSync(path.join(root, 'mise.toml')), false);
  assert.equal(fs.readFileSync(path.join(root, 'CLAUDE.md'), 'utf8'), 'existing');
});
test('missing content is rejected before any destination writes', t => {
  const { root, file, spec } = fixture(t);
  assert.throws(() => install(spec([file('mise.toml', 'new'), { path: 'CLAUDE.md', expected_sha256: null }])), /Missing content/);
  assert.deepEqual(fs.readdirSync(root), []);
});
test('explicit alias updates canonical bytes while preserving symlink', t => {
  const { root, file, spec } = fixture(t);
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'old');
  fs.symlinkSync('CLAUDE.md', path.join(root, 'AGENTS.md'));
  const input = { ...spec([file('AGENTS.md', 'new', digest('old'))]), aliases: [{ path: 'AGENTS.md', target: 'CLAUDE.md' }] };
  install(input);
  assert.equal(fs.readlinkSync(path.join(root, 'AGENTS.md')), 'CLAUDE.md');
  assert.equal(fs.readFileSync(path.join(root, 'CLAUDE.md'), 'utf8'), 'new');
  const timestamp = fs.statSync(path.join(root, 'CLAUDE.md')).mtimeMs;
  assert.equal(install(input).files[0].status, 'unchanged');
  assert.equal(fs.statSync(path.join(root, 'CLAUDE.md')).mtimeMs, timestamp);
});
test('duplicate alias and canonical destination is ambiguous', t => {
  const { root, file, spec } = fixture(t);
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'old');
  fs.symlinkSync('CLAUDE.md', path.join(root, 'AGENTS.md'));
  assert.throws(() => install({ ...spec([file('AGENTS.md', 'new', digest('old')), file('CLAUDE.md', 'other', digest('old'))]), aliases: [{ path: 'AGENTS.md', target: 'CLAUDE.md' }] }), /Duplicate or aliased/);
});
test('parent symlink cannot redirect writes outside checkout', t => {
  const { root, base, file, spec } = fixture(t);
  fs.symlinkSync(base, path.join(root, 'scripts'));
  assert.throws(() => install(spec([file('scripts/agent_collaboration.mjs', 'payload')])), /Unsafe parent/);
  assert.equal(fs.existsSync(path.join(base, 'agent_collaboration.mjs')), false);
});
test('file symlink cannot redirect writes outside checkout', t => {
  const { root, base, file, spec } = fixture(t);
  fs.writeFileSync(path.join(base, 'outside'), 'preserve');
  fs.symlinkSync(path.join(base, 'outside'), path.join(root, 'CLAUDE.md'));
  assert.throws(() => install(spec([file('CLAUDE.md', 'payload', digest('preserve'))])), /regular file/);
  assert.equal(fs.readFileSync(path.join(base, 'outside'), 'utf8'), 'preserve');
});
test('alias pointing outside checkout is rejected', t => {
  const { root, base, file, spec } = fixture(t);
  fs.writeFileSync(path.join(base, 'outside'), 'preserve');
  fs.symlinkSync(path.join(base, 'outside'), path.join(root, 'AGENTS.md'));
  assert.throws(() => install({ ...spec([file('AGENTS.md', 'payload')]), aliases: [{ path: 'AGENTS.md', target: 'CLAUDE.md' }] }), /Alias changed/);
});
test('second baseline after external edit is rejected and external bytes survive', t => {
  const { root, file, spec } = fixture(t);
  const input = spec([file('CLAUDE.md', 'installed')]);
  install(input);
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'concurrent edit');
  assert.throws(() => install(input), /Stale baseline/);
  assert.equal(fs.readFileSync(path.join(root, 'CLAUDE.md'), 'utf8'), 'concurrent edit');
});
test('cooperating installer lock refuses a concurrent writer', t => {
  const { root, file, spec } = fixture(t);
  const lock = path.join(os.tmpdir(), `epubtomp3-collaboration-install-${digest(fs.realpathSync(root))}.lock`);
  fs.mkdirSync(lock);
  try { assert.throws(() => install(spec([file('CLAUDE.md', 'new')])), /EEXIST/); }
  finally { fs.rmdirSync(lock); }
  assert.deepEqual(fs.readdirSync(root), []);
});
test('backup preserves original bytes and existing file permissions', t => {
  const { root, base, file, spec } = fixture(t);
  const backup = path.join(base, 'backups');
  fs.mkdirSync(backup);
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'original\n', { mode: 0o640 });
  fs.chmodSync(path.join(root, 'CLAUDE.md'), 0o666);
  const result = install({ ...spec([file('CLAUDE.md', 'replacement\n', digest('original\n'))]), backup_dir: backup });
  assert.equal(fs.readFileSync(path.join(result.backup, 'CLAUDE.md'), 'utf8'), 'original\n');
  assert.equal(fs.statSync(path.join(root, 'CLAUDE.md')).mode & 0o777, 0o666);
});
test('backup inside checkout and unapproved paths are rejected', t => {
  const { root, file, spec } = fixture(t);
  assert.throws(() => install({ ...spec([file('CLAUDE.md', 'new')]), backup_dir: root }), /outside checkout/);
  for (const name of ['../CLAUDE.md', 'crates/main.rs', '/tmp/CLAUDE.md', 'docs/../CLAUDE.md']) {
    assert.throws(() => install(spec([file(name, 'new')])), /not an allowed/);
  }
  assert.deepEqual(fs.readdirSync(root), []);
});
test('CLI rejects malformed input and command arguments', t => {
  fixture(t);
  for (const [args, input] of [[[], '{'], [['--apply'], '{}']]) {
    const child = spawnSync(process.execPath, [script, ...args], { input, encoding: 'utf8' });
    assert.equal(child.status, 1);
    assert.match(child.stderr, /Collaboration install blocked/);
  }
});
