#!/usr/bin/env node
// Messages coordinate agents; their contents never become executable commands.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const PROTOCOL = 'epubtomp3-collaboration/v1';
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const COMMIT = /^[a-f0-9]{40}$/;
const TIMEOUT = 15000;
const fail = message => { throw new Error(message); };
const populated = value => typeof value === 'string' ? value.trim().length > 0
  : Array.isArray(value) ? value.length > 0 && value.every(populated)
    : value !== null && typeof value === 'object' && Object.keys(value).length > 0;
const field = (value, name) => { if (!populated(value[name])) fail(`Missing or empty ${name}`); };

export function validateConfig(config) {
  if (config?.protocol !== PROTOCOL) fail('Unsupported collaboration protocol');
  field(config, 'workspace');
  if (typeof config.workspace !== 'string') fail('Invalid workspace');
  for (const role of ['mac', 'arch']) {
    if (typeof config.roles?.[role]?.project !== 'string' || !config.roles[role].project.trim()) fail(`Missing ${role} project`);
    const id = config.roles[role].project_id;
    if (id !== undefined && (typeof id !== 'string' || !UUID.test(id))) fail(`Invalid ${role} project_id`);
  }
  if (config.roles.mac.project === config.roles.arch.project) fail('Roles require separate mailboxes');
  if (typeof config.ssh_host !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(config.ssh_host)) fail('Invalid SSH host');
  return config;
}

export function validateEnvelope(body, { config, sender, recipient }) {
  if (!body || Array.isArray(body) || body.protocol !== PROTOCOL) fail('Foreign or malformed protocol envelope');
  if (body.sender !== sender || body.recipient !== recipient || sender === recipient) fail('Envelope role/direction mismatch');
  field(body, 'task_id');
  if (typeof body.task_id !== 'string') fail('Invalid task_id');
  if (!['handshake', 'acknowledgement', 'request', 'result'].includes(body.kind)) fail('Unsupported message kind');
  if (body.kind === 'acknowledgement' || body.kind === 'result') {
    if (typeof body.in_reply_to !== 'string' || !UUID.test(body.in_reply_to)) fail('Reply requires exact in_reply_to message UUID');
  }
  if (body.kind === 'request') {
    if (typeof body.commit !== 'string' || !COMMIT.test(body.commit)) fail('Request requires full lowercase commit SHA');
    for (const name of ['repo', 'branch', 'platform', 'owner', 'scope', 'acceptance', 'authorization']) field(body, name);
    if (typeof body.repo !== 'string' || typeof body.branch !== 'string' || typeof body.platform !== 'string' || typeof body.owner !== 'string') fail('Invalid request identity');
    if (typeof body.authorization !== 'string') fail('Authorization must cite current user/canonical policy');
    if (body.reply_to?.workspace !== config.workspace || body.reply_to?.project !== config.roles[sender].project) fail('reply_to must identify the sender mailbox');
  }
  if (body.kind === 'result') {
    if (!['passed', 'failed', 'blocked', 'cancelled'].includes(body.status)) fail('Invalid result status');
    if (typeof body.observed_commit !== 'string' || !COMMIT.test(body.observed_commit)) fail('Result requires actual observed commit SHA');
    field(body, 'environment');
    field(body, 'evidence');
  }
  return body;
}

export const posixQuote = value => `'${String(value).replaceAll("'", "'\\''")}'`;

export function commandFor(config, role, args) {
  if (role === 'arch') return { command: 'ai-memory', args };
  const remote = ['env', 'RUST_LOG=error', 'NO_COLOR=1', 'ai-memory', ...args].map(posixQuote).join(' ');
  return { command: '/usr/bin/ssh', args: ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', config.ssh_host, remote] };
}

export function nativeRunner(command, args, options) {
  return spawnSync(command, args, { ...options, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, RUST_LOG: 'error', NO_COLOR: '1' } });
}

export function createClient({ config, role, runner = nativeRunner }) {
  validateConfig(config);
  if (!['mac', 'arch'].includes(role)) fail('Role must be mac or arch');
  const other = role === 'mac' ? 'arch' : 'mac';
  const scope = ['--workspace', config.workspace, '--project', config.roles[role].project];
  const invoke = (args, input) => {
    const command = commandFor(config, role, ['message', ...args]);
    const result = runner(command.command, command.args, { input, timeout: TIMEOUT });
    if (result.error || result.signal || result.status !== 0) {
      const error = new Error(result.error?.code === 'ETIMEDOUT'
        ? 'ai-memory timed out; outcome may be ambiguous. Reconcile the exact outbox/inbox before any retry.'
        : `ai-memory failed${result.status === null ? '' : ` (exit ${result.status})`}: ${result.stderr ?? result.error?.message ?? result.signal ?? ''}`);
      error.exitCode = Number.isInteger(result.status) && result.status !== 0 ? result.status : 1;
      throw error;
    }
    try { return JSON.parse(result.stdout); } catch { fail('ai-memory returned malformed JSON; no follow-up mutation attempted'); }
  };
  const list = box => {
    if (!['inbox', 'outbox'].includes(box)) fail('Invalid mailbox');
    const output = invoke(['list', ...scope, ...(box === 'outbox' ? ['--outbox'] : []), '--limit', '200', '--json']);
    if (!Array.isArray(output)) fail('Expected a JSON message array');
    return output;
  };
  const mutate = (operation, id) => {
    if (typeof id !== 'string' || !UUID.test(id)) fail('An explicit message UUID is required');
    const box = operation === 'claim' ? 'inbox' : 'outbox';
    const matches = list(box).filter(message => message.id === id);
    if (matches.length !== 1) fail('Exact message not found uniquely in the pending mailbox; nothing changed');
    const message = matches[0];
    if (message.state !== 'pending') fail('Message is not pending; nothing changed');
    let body;
    try { body = typeof message.body === 'string' ? JSON.parse(message.body) : message.body; }
    catch { fail('Message body is not JSON; nothing changed'); }
    const sender = operation === 'claim' ? other : role;
    const recipient = operation === 'claim' ? role : other;
    validateEnvelope(body, { config, sender, recipient });
    for (const [name, expectedRole] of [['from_project_id', sender], ['to_project_id', recipient]]) {
      const knownId = config.roles[expectedRole].project_id;
      if (knownId && message[name] !== knownId) fail('Message project provenance mismatch; nothing changed');
    }
    return invoke([operation === 'claim' ? 'pop' : 'cancel', ...scope, '--id', id, '--json']);
  };
  return {
    list,
    send(body) {
      validateEnvelope(body, { config, sender: role, recipient: other });
      const pending = list('outbox');
      if (pending.length >= 200) fail('Outbox reached the CLI inspection limit; reconcile pending mail before sending');
      for (const message of pending) {
        let existing;
        try {
          existing = typeof message.body === 'string' ? JSON.parse(message.body) : message.body;
          validateEnvelope(existing, { config, sender: role, recipient: other });
        } catch { continue; }
        const identity = ['kind', 'task_id', 'commit', 'platform', 'in_reply_to'];
        if (message.state === 'pending' && identity.every(key => existing[key] === body[key])) {
          fail(`Matching request is already pending (${message.id}); reconcile or explicitly cancel it before sending again`);
        }
      }
      try {
        return invoke(['send', '--from-workspace', config.workspace, '--from-project', config.roles[role].project,
          '--to-workspace', config.workspace, '--to-project', config.roles[other].project, '--json'], JSON.stringify(body));
      } catch (error) {
        error.message += '\nReconcile the outbox before any resend; a failed response does not prove delivery failed.';
        throw error;
      }
    },
    claim: id => mutate('claim', id),
    cancel: id => mutate('cancel', id),
  };
}

export function main(argv = process.argv.slice(2)) {
  if (argv[0] !== '--role' || !['mac', 'arch'].includes(argv[1])) fail('Usage: agent_collaboration.mjs --role mac|arch inbox|outbox|send FILE|claim ID|cancel ID');
  const [,, action, argument, ...extra] = argv;
  if (!['inbox', 'outbox', 'send', 'claim', 'cancel'].includes(action) || extra.length ||
      (['inbox', 'outbox'].includes(action) ? argument !== undefined : argument === undefined)) fail('Invalid action or arguments');
  const config = JSON.parse(readFileSync(new URL('../.agents/collaboration.json', import.meta.url), 'utf8'));
  const client = createClient({ config, role: argv[1] });
  const result = action === 'inbox' || action === 'outbox' ? client.list(action)
    : action === 'send' ? client.send(JSON.parse(readFileSync(argument, 'utf8'))) : client[action](argument);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = error.exitCode ?? 1;
  }
}
