#!/usr/bin/env node
// Controlled queue fixtures verify transport, not another agent's decisions or app behavior.
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient, validateConfig } from './agent_collaboration.mjs';
import { doctor } from './collaboration_doctor.mjs';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

export function revalidate({ config, role, allowQueueFixtures = false, diagnose = doctor,
  makeClient = options => createClient(options), uniqueId = randomUUID, onProgress = () => {} }) {
  validateConfig(config);
  requireValue(['mac', 'arch'].includes(role), 'Role must be mac or arch');
  requireValue(allowQueueFixtures === true, 'Queue fixtures require --allow-queue-fixtures');
  const nonce = uniqueId();
  requireValue(typeof nonce === 'string' && UUID.test(nonce), 'Fixture nonce must be a UUID');
  const report = { kind: 'deterministic_transport', role, models_invoked: false, ok: false,
    task_ids: [`TRANSPORT-${nonce}`, `TRANSPORT-CANCEL-${nonce}`], checks: [], fixtures: [] };
  onProgress({ kind: 'fixture_scope', role, task_ids: report.task_ids });
  report.doctor = diagnose({ config, role });
  if (!report.doctor.ok) { report.failure = { step: 'doctor', reason: 'read_only_preflight_failed' }; return report; }
  const other = role === 'mac' ? 'arch' : 'mac';
  const clients = Object.fromEntries([role, other].map(identity => [identity,
    makeClient({ config, role: identity, transportRole: role })]));
  let step = 'send';
  const check = name => report.checks.push({ name, status: 'passed' });
  const own = (body, sender) => body?.protocol === config.protocol && body.sender === sender
    && body.recipient === (sender === role ? other : role) && report.task_ids.includes(body.task_id);
  const envelope = (sender, kind, task_id, extra = {}) => ({ protocol: config.protocol, kind,
    task_id, sender, recipient: sender === role ? other : role,
    scope: 'User-authorized deterministic queue fixture only; no agent/app/device action.', ...extra });
  const sent = (sender, body) => {
    const output = clients[sender].send(body);
    requireValue(typeof output?.message_id === 'string' && UUID.test(output.message_id), 'Missing send receipt');
    report.fixtures.push({ id: output.message_id, sender, task_id: body.task_id });
    onProgress({ kind: 'sent_fixture', id: output.message_id, sender, task_id: body.task_id });
    return output.message_id;
  };
  const expectRefusal = (operation, pattern) => {
    let refused = false;
    try { operation(); } catch (error) { if (!pattern.test(error.message)) throw error; refused = true; }
    requireValue(refused, 'Expected exact-operation refusal');
  };
  try {
    const request = envelope(role, 'handshake', report.task_ids[0]);
    const requestId = sent(role, request);
    check(step);
    step = 'duplicate_refused';
    expectRefusal(() => sent(role, request), /already pending/);
    check(step);
    step = 'receiver_claim';
    const claimed = clients[other].claim(requestId)?.message;
    requireValue(claimed?.id === requestId && claimed.state === 'claimed', 'Invalid claim receipt');
    const body = JSON.parse(claimed.body);
    requireValue(own(body, role) && body.task_id === request.task_id, 'Claim correlation mismatch');
    check(step);
    step = 'claim_once';
    expectRefusal(() => clients[other].claim(requestId), /not found/);
    check(step);
    step = 'correlated_round_trip';
    const replyId = sent(other, envelope(other, 'acknowledgement', request.task_id, { in_reply_to: requestId }));
    const reply = clients[role].claim(replyId)?.message;
    const replyBody = JSON.parse(reply?.body ?? 'null');
    requireValue(reply?.id === replyId && reply.state === 'claimed' && own(replyBody, other)
      && replyBody.in_reply_to === requestId && replyBody.task_id === request.task_id, 'Reply correlation mismatch');
    check(step);
    step = 'cancel_exact_fixture';
    const cancelId = sent(role, envelope(role, 'handshake', report.task_ids[1]));
    requireValue(clients[other].list('inbox').some(message => message.id === cancelId), 'Receiver cannot see fixture');
    clients[role].cancel(cancelId);
    requireValue(!clients[other].list('inbox').some(message => message.id === cancelId), 'Cancelled fixture remains');
    expectRefusal(() => clients[other].claim(cancelId), /not found/);
    expectRefusal(() => clients[role].cancel(cancelId), /not found/);
    check(step);
  } catch (error) {
    // Tool output can contain private data. Exact IDs and step identify what to reconcile.
    report.failure = { step, reason: 'transport_check_failed', exit_status: error.exitCode ?? null };
  } finally {
    const cleanup = [];
    for (const sender of [role, other]) {
      try {
        const pending = clients[sender].list('outbox');
        requireValue(pending.length < 200, 'Cleanup cannot inspect beyond the CLI limit');
        for (const message of pending) {
          let body;
          try { body = JSON.parse(message.body); } catch { continue; }
          // Include ambiguous sends found by our unique task IDs, never unrelated mail.
          if (message.state === 'pending' && own(body, sender)) {
            clients[sender].cancel(message.id);
            cleanup.push({ id: message.id, sender });
          }
        }
        const remaining = clients[sender].list('outbox');
        requireValue(remaining.length < 200, 'Cleanup result may be truncated');
        requireValue(!remaining.some(message => {
          try { return own(JSON.parse(message.body), sender); } catch { return false; }
        }), 'Fixture remains pending');
      } catch {
        report.cleanup_unverified = true;
      }
    }
    report.cleanup = cleanup;
  }
  report.ok = !report.failure && !report.cleanup_unverified;
  return report;
}

export function main(argv = process.argv.slice(2)) {
  requireValue(argv.length === 3 && argv[0] === '--role' && argv[2] === '--allow-queue-fixtures',
    'Usage: revalidate_collaboration.mjs --role mac|arch --allow-queue-fixtures');
  const config = JSON.parse(readFileSync(new URL('../.agents/collaboration.json', import.meta.url), 'utf8'));
  const report = revalidate({ config, role: argv[1], allowQueueFixtures: true,
    onProgress: event => process.stderr.write(`${JSON.stringify(event)}\n`) });
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!report.ok) process.exitCode = 1;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch { process.stderr.write('Invalid revalidation invocation; queue fixtures require explicit authorization.\n'); process.exitCode = 1; }
}
