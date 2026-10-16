import test from 'node:test';
import assert from 'node:assert/strict';
import { doctor, main } from './collaboration_doctor.mjs';

const config = { protocol: 'epubtomp3-collaboration/v1', workspace: 'default', ssh_host: 'arch', roles: {
  mac: { project: 'epubtomp3-mac', project_id: '01a141b0-86c9-7972-ae68-7f0cb66449db' },
  arch: { project: 'Epub-to-Mp3', project_id: '019f8f88-5ba3-7133-a527-6b536bbfb668' },
} };
const projects = Object.values(config.roles).map(role => ({ workspace_name: 'default', project_name: role.project, project_id: role.project_id }));
const status = { version: '3.0.0', bind: '127.0.0.1:49374', db_path: '/db/memory.sqlite', client: { server_url: 'http://127.0.0.1:49374', auth: 'SECRET' } };
const help = '--workspace --project --outbox --limit --json';
function fixture({ role = 'arch', overrides = {}, settings = config } = {}) {
  const calls = [];
  const report = doctor({ config: settings, role, runner(command, args, options) {
    calls.push({ command, args, options });
    const index = calls.length - 1;
    if (overrides[index]) return overrides[index];
    const actual = command === 'ai-memory' ? args : args.at(-1);
    const output = actual.includes('status') ? JSON.stringify(status) : actual.includes('--version') ? 'ai-memory 3.0.0\n' : actual.includes('--help') ? help
      : actual.includes('list-projects') ? JSON.stringify(projects) : '[]';
    return { status: 0, stdout: output };
  } });
  return { report, calls };
}
const failed = report => report.checks.filter(check => check.status === 'failed');

test('Arch verifies actual scoped UUIDs and cap200 mailbox capability without mutations', () => {
  const { report, calls } = fixture();
  assert.equal(report.ok, true);
  assert.equal(report.transport, 'local_cli');
  assert.equal(calls.length, 6);
  for (const call of calls) {
    assert.equal(call.command, 'ai-memory');
    assert.equal(call.options.timeout, 15000);
    assert.ok(['--version', 'message', 'list-projects', 'status'].includes(call.args[0]));
    assert.ok(!call.args.some(argument => ['send', 'pop', 'cancel', 'register', 'run'].includes(argument)));
  }
  assert.deepEqual(calls[4].args, ['message', 'list', '--workspace', 'default', '--project', 'epubtomp3-mac', '--limit', '200', '--json']);
  assert.deepEqual(calls[5].args, ['message', 'list', '--workspace', 'default', '--project', 'Epub-to-Mp3', '--limit', '200', '--json']);
  assert.equal(report.checks[3].source, 'server_project_uuids');
});

test('Mac checks local version and addresses coordination server only via bounded batch SSH', () => {
  const { report, calls } = fixture({ role: 'mac' });
  assert.equal(report.ok, true);
  assert.deepEqual(calls[0].args, ['--version']);
  for (const call of calls.slice(1)) {
    assert.equal(call.command, '/usr/bin/ssh');
    assert.deepEqual(call.args.slice(0, 7), ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', 'arch']);
  }
});

test('names without verified UUIDs never establish server identity', () => {
  const names = projects.map(({ project_id, ...project }) => project);
  const { report } = fixture({ overrides: { 3: { status: 0, stdout: JSON.stringify(names) } } });
  assert.equal(report.ok, false);
  assert.equal(failed(report)[0].name, 'coordination_database_identity');
});

test('wrong UUID, workspace, missing role or duplicate project fails closed', () => {
  for (const entries of [projects.map(project => ({ ...project, project_id: config.roles.mac.project_id })), projects.map(project => ({ ...project, workspace_name: 'foreign' })), projects.slice(1), [...projects, projects[0]]]) {
    assert.equal(fixture({ overrides: { 3: { status: 0, stdout: JSON.stringify(entries) } } }).report.ok, false);
  }
});

test('missing configured UUID fails closed even if project names match', () => {
  const settings = structuredClone(config);
  delete settings.roles.mac.project_id;
  assert.equal(fixture({ settings }).report.ok, false);
});

test('command failure, timeout and malformed JSON are reported without raw secret output', () => {
  for (const result of [{ status: 42, stderr: 'SECRET=private', stdout: '' }, { status: null, error: { code: 'ETIMEDOUT' }, stderr: 'SECRET=private' }, { status: 0, stdout: 'SECRET=private' }]) {
    const { report } = fixture({ overrides: { 3: result } });
    assert.equal(report.ok, false);
    assert.equal(failed(report).length, 1);
    assert.doesNotMatch(JSON.stringify(report), /SECRET|private/);
  }
});

test('help alone cannot establish accepted limit: actual cap200 read must pass', () => {
  const { report } = fixture({ overrides: { 4: { status: 2, stderr: 'limit exceeds max' } } });
  assert.equal(report.ok, false);
  assert.equal(failed(report)[0].name, 'mac_bounded_inbox');
});

test('unsupported CLI flags and unrecognized version fail closed', () => {
  for (const overrides of [{ 0: { status: 0, stdout: 'unknown version' } }, { 1: { status: 0, stdout: '--json' } }]) {
    assert.equal(fixture({ overrides }).report.ok, false);
  }
});

test('mail bodies remain private and overlong/nonarray listings fail closed', () => {
  const privateMail = { body: 'SECRET', id: 'private' };
  const { report } = fixture({ overrides: { 4: { status: 0, stdout: JSON.stringify([privateMail]) } } });
  assert.equal(report.ok, true);
  assert.equal(report.checks[4].pending_count, 1);
  assert.doesNotMatch(JSON.stringify(report), /SECRET|private/);
  for (const listing of [{ messages: [] }, Array(201).fill(privateMail)]) {
    assert.equal(fixture({ overrides: { 4: { status: 0, stdout: JSON.stringify(listing) } } }).report.ok, false);
  }
});

test('invalid roles, arguments and SSH injection are rejected before probing', () => {
  assert.throws(() => fixture({ role: 'other' }));
  assert.throws(() => fixture({ settings: { ...config, ssh_host: 'arch; touch /tmp/never' } }));
  for (const args of [[], ['--role', 'mac', '--revalidate'], ['--role', 'other']]) assert.throws(() => main(args));
});

test('CLI names with null IDs use only the exact readonly server database identity', () => {
  const names = projects.map(project => ({ ...project, project_id: null }));
  const rows = projects.map(project => ({ workspace_name: project.workspace_name, project_name: project.project_name, project_hex: project.project_id.replaceAll('-', '') }));
  for (const role of ['arch', 'mac']) {
    const offset = role === 'mac' ? 1 : 0;
    const { report, calls } = fixture({ role, overrides: {
      [3 + offset]: { status: 0, stdout: JSON.stringify(names) },
      [4 + offset]: { status: 0, stdout: JSON.stringify(rows) },
    } });
    assert.equal(report.ok, true);
    const call = calls[4 + offset];
    if (role === 'arch') {
      assert.equal(call.command, 'sqlite3');
      assert.deepEqual(call.args.slice(0, 3), ['-readonly', '-json', '/db/memory.sqlite']);
      assert.match(call.args[3], /^SELECT /);
      assert.match(call.args[3], /WHERE w.name='default'/);
    } else {
      assert.equal(call.command, '/usr/bin/ssh');
      assert.match(call.args.at(-1), /'sqlite3' '-readonly' '-json' '\/db\/memory.sqlite'/);
    }
    assert.equal(report.checks[4 + offset].source, 'readonly_local_server_database');
    assert.doesNotMatch(JSON.stringify(report), /SECRET|memory.sqlite/);
  }
});

test('database fallback rejects wrong IDs, duplicate names, schema errors and unavailable sqlite', () => {
  const names = projects.map(project => ({ ...project, project_id: null }));
  const rows = projects.map(project => ({ ...project, project_hex: project.project_id.replaceAll('-', '') }));
  for (const output of [[], [rows[0], rows[0], rows[1]], rows.map(row => ({ ...row, project_hex: 'f'.repeat(32) })), {}]) {
    const { report } = fixture({ overrides: { 3: { status: 0, stdout: JSON.stringify(names) }, 4: { status: 0, stdout: JSON.stringify(output) } } });
    assert.equal(report.ok, false);
    assert.equal(failed(report)[0].name, 'coordination_database_identity');
  }
  const { report } = fixture({ overrides: { 3: { status: 0, stdout: JSON.stringify(names) }, 4: { status: 127 } } });
  assert.equal(report.ok, false);
});

test('database fallback requires matching loopback status endpoint and absolute path', () => {
  const names = projects.map(project => ({ ...project, project_id: null }));
  for (const invalid of [
    { ...status, client: { server_url: 'https://example.com', auth: 'SECRET' } },
    { ...status, client: { server_url: 'http://127.0.0.1:9876' } },
    { ...status, client: { server_url: 'http://secret:SECRET@127.0.0.1:49374' } },
    { ...status, db_path: 'relative.sqlite' },
    { ...status, db_path: '/tmp/a\0b' },
  ]) {
    const { report, calls } = fixture({ overrides: { 2: { status: 0, stdout: JSON.stringify(invalid) }, 3: { status: 0, stdout: JSON.stringify(names) } } });
    assert.equal(report.ok, false);
    assert.ok(calls.every(call => call.command !== 'sqlite3'));
    assert.doesNotMatch(JSON.stringify(report), /SECRET/);
  }
});

test('SQLite literals quote configured project names, with SSH quoting as a separate boundary', () => {
  const settings = structuredClone(config);
  settings.roles.mac.project = "mac' OR 1=1;--";
  const names = Object.values(settings.roles).map(role => ({ workspace_name: settings.workspace, project_name: role.project, project_id: null }));
  const rows = Object.values(settings.roles).map(role => ({ workspace_name: settings.workspace, project_name: role.project, project_hex: role.project_id.replaceAll('-', '') }));
  const { report, calls } = fixture({ settings, overrides: { 3: { status: 0, stdout: JSON.stringify(names) }, 4: { status: 0, stdout: JSON.stringify(rows) } } });
  assert.equal(report.ok, true);
  assert.match(calls[4].args[3], /'mac'' OR 1=1;--'/);
});
