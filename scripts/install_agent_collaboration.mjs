#!/usr/bin/env node
// Reviewed installer code stays static; all deployment data arrives as JSON stdin.
import * as fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const allowed = new Set([
  'CLAUDE.md', 'AGENTS.md', 'mise.toml', '.agents/collaboration.json',
  'docs/agents/mac-arch-collaboration.md', 'docs/agents/retro-collaboration-controls.md',
  'docs/agents/collaboration-operations.md',
  ...['agent_collaboration', 'install_agent_collaboration', 'collaboration_doctor', 'revalidate_collaboration']
    .flatMap(name => [`scripts/${name}.mjs`, `scripts/test_${name}.mjs`]),
]);
const inside = (root, target) => target.startsWith(`${root}${path.sep}`);
const exists = target => { try { return fs.lstatSync(target); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
const check = (condition, message) => { if (!condition) throw new Error(message); };
function relative(value) {
  check(typeof value === 'string' && allowed.has(value), `Path is not an allowed collaboration file: ${value}`);
  return value;
}
// Parent symlinks are always refused, including aliases that happen to stay in root.
function safePath(root, name) {
  const target = path.join(root, name);
  let cursor = root;
  for (const component of name.split('/').slice(0, -1)) {
    cursor = path.join(cursor, component);
    const stat = exists(cursor);
    check(!stat || (stat.isDirectory() && !stat.isSymbolicLink()), `Unsafe parent: ${name}`);
  }
  return target;
}
function read(root, name) {
  const target = safePath(root, name);
  const stat = exists(target);
  check(!stat || (stat.isFile() && !stat.isSymbolicLink()), `Expected a regular file: ${name}`);
  return { bytes: stat ? fs.readFileSync(target) : null, mode: stat ? stat.mode & 0o777 : 0o644 };
}
function verifyAliases(root, aliases) {
  for (const [name, destination] of aliases) {
    const target = safePath(root, name);
    const stat = exists(target);
    check(stat?.isSymbolicLink(), `Expected preserved symlink: ${name}`);
    check(path.resolve(path.dirname(target), fs.readlinkSync(target)) === path.join(root, destination), `Alias changed: ${name}`);
    check(read(root, destination).bytes !== null, `Alias target is missing: ${name}`);
  }
}
function snapshot(spec) {
  check(spec && spec.version === 1 && ['plan', 'apply'].includes(spec.mode), 'Expected version 1 and plan/apply mode');
  check(typeof spec.root === 'string' && path.isAbsolute(spec.root), 'Root must be absolute');
  const root = fs.realpathSync(spec.root);
  check(fs.statSync(root).isDirectory(), 'Root must be a directory');
  check(Array.isArray(spec.files) && spec.files.length > 0, 'Files must be nonempty');
  check(spec.aliases === undefined || Array.isArray(spec.aliases), 'Aliases must be an array');
  const aliases = new Map();
  for (const alias of spec.aliases ?? []) {
    // The repository's only instruction alias is explicit, never inferred.
    check(alias?.path === 'AGENTS.md' && alias.target === 'CLAUDE.md' && !aliases.has(alias.path), 'Only AGENTS.md -> CLAUDE.md is a supported alias');
    aliases.set(alias.path, alias.target);
  }
  verifyAliases(root, aliases);
  const seen = new Set();
  const files = spec.files.map(file => {
    check(file && typeof file === 'object', 'Invalid file entry');
    const requested = relative(file.path);
    const name = aliases.get(requested) ?? requested;
    check(!seen.has(name), `Duplicate or aliased target: ${name}`);
    seen.add(name);
    check(typeof file.content === 'string', `Missing content: ${name}`);
    check(file.expected_sha256 === null || (typeof file.expected_sha256 === 'string' && /^[0-9a-f]{64}$/.test(file.expected_sha256)), `Invalid expected SHA256: ${name}`);
    const content = Buffer.from(file.content, 'utf8');
    const current = read(root, name);
    const unchanged = current.bytes?.equals(content) ?? false;
    check(unchanged || (current.bytes === null ? file.expected_sha256 === null : hash(current.bytes) === file.expected_sha256), `Stale baseline: ${name}`);
    return { name, ...current, content, unchanged };
  });
  let backup = null;
  if (spec.backup_dir !== undefined) {
    check(typeof spec.backup_dir === 'string' && path.isAbsolute(spec.backup_dir), 'Backup directory must be absolute');
    // Require an existing directory so symlink resolution is authoritative.
    backup = fs.realpathSync(spec.backup_dir);
    check(fs.statSync(backup).isDirectory() && backup !== root && !inside(root, backup), 'Backup directory must be outside checkout');
  }
  return { root, aliases, files, backup };
}
function unchangedSince(root, file) {
  const now = read(root, file.name).bytes;
  check(now === null ? file.bytes === null : file.bytes !== null && now.equals(file.bytes), `Concurrent change: ${file.name}`);
}

export function install(spec) {
  const state = snapshot(spec);
  const { root, aliases, files, backup } = state;
  const result = { mode: spec.mode, files: files.map(file => ({ path: file.name, status: file.unchanged ? 'unchanged' : 'update', sha256: hash(file.content) })) };
  if (spec.mode === 'plan') return result;
  const lock = path.join(os.tmpdir(), `epubtomp3-collaboration-install-${hash(root)}.lock`);
  // Atomic mkdir coordinates cooperating installers across inode replacement.
  fs.mkdirSync(lock, { mode: 0o700 });
  const temporaries = [];
  try {
    verifyAliases(root, aliases);
    for (const file of files) unchangedSince(root, file);
    const changes = files.filter(file => !file.unchanged);
    const backupRoot = backup && changes.some(file => file.bytes !== null)
      ? fs.mkdtempSync(path.join(backup, 'install-')) : null;
    // Prepare every replacement before committing any file. A failed validation
    // leaves all destination bytes untouched; unexpected I/O failure is surfaced.
    for (const file of changes) {
      const target = safePath(root, file.name);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      if (backupRoot && file.bytes !== null) {
        const saved = path.join(backupRoot, file.name);
        fs.mkdirSync(path.dirname(saved), { recursive: true });
        fs.writeFileSync(saved, file.bytes, { flag: 'wx', mode: 0o600 });
      }
      const temporary = path.join(path.dirname(target), `.collaboration-${randomUUID()}.tmp`);
      const descriptor = fs.openSync(temporary, 'wx', file.mode);
      temporaries.push(temporary);
      try { fs.writeFileSync(descriptor, file.content); fs.fchmodSync(descriptor, file.mode); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
      file.temporary = temporary;
    }
    verifyAliases(root, aliases);
    for (const file of files) unchangedSince(root, file);
    for (const file of changes) {
      verifyAliases(root, aliases);
      unchangedSince(root, file);
      fs.renameSync(file.temporary, safePath(root, file.name));
    }
    if (backupRoot) result.backup = backupRoot;
    return result;
  } finally {
    for (const temporary of temporaries) fs.rmSync(temporary, { force: true });
    fs.rmdirSync(lock);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    check(process.argv.length === 2, 'Pass the JSON deployment spec on stdin; no command arguments');
    const input = fs.readFileSync(0, 'utf8');
    check(Buffer.byteLength(input) <= 8 * 1024 * 1024, 'Deployment spec exceeds 8 MiB');
    console.log(JSON.stringify(install(JSON.parse(input))));
  } catch (error) { console.error(`Collaboration install blocked: ${error.message}`); process.exitCode = 1; }
}
