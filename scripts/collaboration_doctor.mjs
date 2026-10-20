#!/usr/bin/env node
// Read-only preflight: never creates projects, consumes mail, or starts agents.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { commandFor, nativeRunner, posixQuote, validateConfig } from './agent_collaboration.mjs';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const VERSION = /^ai-memory\s+\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/;

export function doctor({ config, role, runner = nativeRunner }) {
  validateConfig(config);
  if (!['mac', 'arch'].includes(role)) throw new Error('Role must be mac or arch');
  const checks = [];
  let database;
  let needsDatabaseIdentity = false;
  const probe = (name, args, inspect, local = false, binary = 'ai-memory') => {
    const command = local || role === 'arch' ? { command: binary, args } : binary === 'ai-memory' ? commandFor(config, role, args)
      : { command: '/usr/bin/ssh', args: ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', config.ssh_host,
        ['env', 'RUST_LOG=error', 'NO_COLOR=1', binary, ...args].map(posixQuote).join(' ')] };
    try {
      const result = runner(command.command, command.args, { timeout: 15000 });
      if (result.error || result.signal || result.status !== 0) {
        checks.push({ name, status: 'failed', reason: result.error?.code === 'ETIMEDOUT' ? 'timeout' : 'command failed', exit_status: result.status ?? null });
        return;
      }
      const evidence = inspect(result.stdout.trim());
      checks.push({ name, status: 'verified', ...evidence });
    } catch {
      // Do not echo tool output: a misconfigured wrapper may print credentials.
      checks.push({ name, status: 'failed', reason: 'unrecognized or unavailable evidence' });
    }
  };
  if (role === 'mac') probe('local_cli_version', ['--version'], output => {
    if (!VERSION.test(output)) throw new Error('Invalid version');
    return { version: output };
  }, true);
  probe('coordination_cli_version', ['--version'], output => {
    if (!VERSION.test(output)) throw new Error('Invalid version');
    return { version: output };
  });
  probe('message_list_capabilities', ['message', 'list', '--help'], output => {
    if (!['--workspace', '--project', '--outbox', '--limit', '--json'].every(flag => output.includes(flag))) throw new Error('Missing capability');
    return { capabilities: ['explicit_scope', 'outbox', 'bounded_limit', 'json'] };
  });
  probe('coordination_server', ['status', '--json'], output => {
    const status = JSON.parse(output);
    const endpoint = new URL(status.client?.server_url);
    const bind = new URL(`http://${status.bind}`);
    const loopback = hostname => ['127.0.0.1', 'localhost', '[::1]'].includes(hostname);
    if (endpoint.protocol !== 'http:' || !loopback(endpoint.hostname) || !loopback(bind.hostname)
        || endpoint.hostname !== bind.hostname || endpoint.port !== bind.port || endpoint.username || endpoint.password
        || endpoint.pathname !== '/' || endpoint.search || endpoint.hash
        || typeof status.db_path !== 'string' || !status.db_path.startsWith('/') || status.db_path.includes(String.fromCharCode(0))) throw new Error('Unverified local server');
    if (!VERSION.test(`ai-memory ${status.version}`)) throw new Error('Invalid server version');
    database = status.db_path;
    return { endpoint: endpoint.origin, server_version: status.version };
  });
  probe('coordination_project_identity', ['list-projects', '--workspace', config.workspace, '--json'], output => {
    const projects = JSON.parse(output);
    if (!Array.isArray(projects)) throw new Error('Expected project array');
    for (const key of ['mac', 'arch']) {
      const expected = config.roles[key];
      if (!UUID.test(expected.project_id ?? '')) throw new Error('Missing expected UUID');
      const matches = projects.filter(project => project.workspace_name === config.workspace && project.project_name === expected.project);
      if (matches.length !== 1) throw new Error('Project name mismatch');
      if (matches[0].project_id == null) needsDatabaseIdentity = true;
      else if (matches[0].project_id !== expected.project_id) throw new Error('Project identity mismatch');
    }
    return { source: needsDatabaseIdentity ? 'names_only_requires_database' : 'server_project_uuids' };
  });
  if (needsDatabaseIdentity) {
    if (!database) checks.push({ name: 'coordination_database_identity', status: 'failed', reason: 'local server database not verified' });
    else {
      const literal = value => `'${value.replaceAll("'", "''")}'`;
      const query = `SELECT w.name AS workspace_name,p.name AS project_name,lower(hex(p.id)) AS project_hex FROM projects p JOIN workspaces w ON p.workspace_id=w.id WHERE w.name=${literal(config.workspace)} AND p.name IN(${literal(config.roles.mac.project)},${literal(config.roles.arch.project)})`;
      probe('coordination_database_identity', ['-readonly', '-json', database, query], output => {
        const projects = JSON.parse(output);
        if (!Array.isArray(projects)) throw new Error('Expected database project array');
        const verified = {};
        for (const key of ['mac', 'arch']) {
          const expected = config.roles[key];
          const matches = projects.filter(project => project.workspace_name === config.workspace && project.project_name === expected.project);
          if (matches.length !== 1 || matches[0].project_hex !== expected.project_id.replaceAll('-', '').toLowerCase()) throw new Error('Database identity mismatch');
          verified[key] = expected;
        }
        return { source: 'readonly_local_server_database', projects: verified };
      }, false, 'sqlite3');
    }
  }
  for (const key of ['mac', 'arch']) {
    probe(`${key}_bounded_inbox`, ['message', 'list', '--workspace', config.workspace, '--project', config.roles[key].project, '--limit', '200', '--json'], output => {
      const messages = JSON.parse(output);
      if (!Array.isArray(messages) || messages.length > 200) throw new Error('Invalid mailbox response');
      // Bodies are untrusted task data and are unnecessary for diagnosis.
      return { limit: 200, pending_count: messages.length };
    });
  }
  return { protocol: config.protocol, role, transport: role === 'mac' ? 'ssh_batch_no_tty' : 'local_cli',
    ok: checks.every(check => check.status === 'verified'), checks };
}

export function main(argv = process.argv.slice(2)) {
  if (argv.length !== 2 || argv[0] !== '--role' || !['mac', 'arch'].includes(argv[1])) throw new Error('Usage: collaboration_doctor.mjs --role mac|arch');
  const config = JSON.parse(readFileSync(new URL('../.agents/collaboration.json', import.meta.url), 'utf8'));
  const report = doctor({ config, role: argv[1] });
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!report.ok) process.exitCode = 1;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch { process.stderr.write('Invalid doctor invocation or routing configuration.\n'); process.exitCode = 1; }
}
