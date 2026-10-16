import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { revalidate } from './revalidate_collaboration.mjs';

const config = { protocol: 'epubtomp3-collaboration/v1', workspace: 'default',
  roles: { mac: { project: 'epubtomp3-mac' }, arch: { project: 'Epub-to-Mp3' } }, ssh_host: 'arch' };
const nonce = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
function fixture(options = {}) {
  const messages = new Map();
  const events = [];
  const unrelated = { id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', sender: 'arch', recipient: 'mac', state: 'pending',
    body: JSON.stringify({ protocol: config.protocol, kind: 'handshake', task_id: 'USER-WORK', sender: 'arch', recipient: 'mac' }) };
  messages.set(unrelated.id, unrelated);
  let serial = 0;
  const makeClient = ({ role, transportRole }) => {
    events.push({ action: 'client', role, transportRole });
    return {
      list(box) {
        events.push({ action: 'list', role, box });
        if (options.failCleanup && box === 'outbox') throw new Error('private token must not appear');
        if (options.fullCleanup && box === 'outbox') return Array.from({ length: 200 }, () => unrelated);
        return [...messages.values()].filter(m => m.state === 'pending' && (box === 'inbox' ? m.recipient : m.sender) === role);
      },
      send(body) {
        events.push({ action: 'send', role });
        const pending = [...messages.values()].some(m => m.sender === role && m.state === 'pending'
          && JSON.parse(m.body).task_id === body.task_id && JSON.parse(m.body).kind === body.kind);
        if (pending && !options.allowDuplicate) throw new Error('already pending');
        const id = `00000000-0000-0000-0000-${String(++serial).padStart(12, '0')}`;
        messages.set(id, { id, sender: role, recipient: body.recipient, state: 'pending', body: JSON.stringify(body) });
        if (options.ambiguousSend) { const error = new Error('private token must not appear'); error.exitCode = 255; throw error; }
        return options.missingReceipt ? {} : { message_id: id };
      },
      claim(id) {
        events.push({ action: 'claim', role, id });
        const m = messages.get(id);
        if (!m || m.state !== 'pending' || m.recipient !== role) throw new Error('not found');
        m.state = 'claimed';
        const body = JSON.parse(m.body);
        if (options.badCorrelation && body.kind === 'acknowledgement') body.in_reply_to = unrelated.id;
        return { message: { ...m, body: JSON.stringify(body) } };
      },
      cancel(id) {
        events.push({ action: 'cancel', role, id });
        const m = messages.get(id);
        if (!m || m.state !== 'pending' || m.sender !== role) throw new Error('not found');
        m.state = 'cancelled';
        return { cancelled: 1 };
      },
    };
  };
  const args = { config, role: 'mac', allowQueueFixtures: true, makeClient,
    diagnose: () => ({ ok: true, checks: [] }), uniqueId: () => nonce,
    onProgress: event => events.push({ action: 'progress', ...event }) };
  return { args, events, messages, unrelated };
}

test('explicit queue authorization is required before diagnosis or any client operation', () => {
  const f = fixture();
  assert.throws(() => revalidate({ ...f.args, allowQueueFixtures: false }), /allow-queue-fixtures/);
  assert.deepEqual(f.events, []);
  const run = spawnSync(process.execPath, [fileURLToPath(new URL('./revalidate_collaboration.mjs', import.meta.url)), '--role', 'mac'], { encoding: 'utf8' });
  assert.equal(run.status, 1);
  assert.equal(run.stdout, '');
  assert.match(run.stderr, /Invalid revalidation invocation/);
});

test('failed doctor prevents all queue clients and mutations', () => {
  const f = fixture();
  const report = revalidate({ ...f.args, diagnose: () => ({ ok: false }) });
  assert.equal(report.ok, false);
  assert.equal(report.failure.step, 'doctor');
  assert.equal(f.events.filter(x => x.action !== 'progress').length, 0);
});

test('both execution locations verify full deterministic round trip and preserve unrelated mail', () => {
  for (const role of ['mac', 'arch']) {
    const f = fixture();
    const report = revalidate({ ...f.args, role });
    assert.equal(report.ok, true);
    assert.equal(report.models_invoked, false);
    assert.equal(report.checks.length, 6);
    assert.equal(f.messages.get(f.unrelated.id).state, 'pending');
    assert.equal([...f.messages.values()].filter(m => m.id !== f.unrelated.id && m.state === 'pending').length, 0);
    for (const e of f.events.filter(e => e.action === 'client')) assert.equal(e.transportRole, role);
    assert.equal(f.events[0].kind, 'fixture_scope');
    assert.equal(f.events.filter(e => e.kind === 'sent_fixture').length, 3);
  }
});

test('wrong reply correlation fails without treating an acknowledgement as acceptance', () => {
  const f = fixture({ badCorrelation: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.failure.step, 'correlated_round_trip');
  assert.equal(f.messages.get(f.unrelated.id).state, 'pending');
});

test('a broken duplicate guard is detected and only its own pending fixtures are cancelled', () => {
  const f = fixture({ allowDuplicate: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.failure.step, 'duplicate_refused');
  assert.equal(report.cleanup.length, 2);
  assert.equal(f.messages.get(f.unrelated.id).state, 'pending');
  assert.ok(f.events.filter(e => e.action === 'cancel').every(e => e.id !== f.unrelated.id));
});

test('ambiguous send is never retried and exact fixture task scope permits reconciliation', () => {
  const f = fixture({ ambiguousSend: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.failure.exit_status, 255);
  assert.equal(f.events.filter(e => e.action === 'send').length, 1);
  assert.equal(report.cleanup.length, 1);
  assert.equal(JSON.stringify(report).includes('private token'), false);
});

test('malformed receipt after delivery is reconciled without another send', () => {
  const f = fixture({ missingReceipt: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.cleanup.length, 1);
  assert.equal(f.events.filter(e => e.action === 'send').length, 1);
});

test('unavailable cleanup is reported as unverified, never silently successful', () => {
  const f = fixture({ badCorrelation: true, failCleanup: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.cleanup_unverified, true);
  assert.equal(JSON.stringify(report).includes('private token'), false);
});

test('a capped outbox cannot prove complete fixture cleanup', () => {
  const f = fixture({ fullCleanup: true });
  const report = revalidate(f.args);
  assert.equal(report.ok, false);
  assert.equal(report.cleanup_unverified, true);
});

test('invalid role or reused non-UUID scope is rejected before any transport operation', () => {
  const f = fixture();
  assert.throws(() => revalidate({ ...f.args, role: 'other' }), /Role/);
  assert.throws(() => revalidate({ ...f.args, uniqueId: () => 'not-unique' }), /nonce/);
  assert.deepEqual(f.events, []);
});
