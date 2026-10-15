import test from 'node:test';
import assert from 'node:assert/strict';
import { commandFor, createClient, posixQuote, validateConfig, validateEnvelope } from './agent_collaboration.mjs';

const protocol = 'epubtomp3-collaboration/v1';
const config = { protocol, workspace: 'default', roles: { mac: { project: 'epubtomp3-mac' }, arch: { project: 'Epub-to-Mp3' } }, ssh_host: 'arch' };
const id = '01a141b0-db18-79b2-8250-41218b980ad8';
const commit = 'a'.repeat(40);
const handshake = (sender = 'mac') => ({ protocol, kind: 'handshake', task_id: 'AGENT-1', sender, recipient: sender === 'mac' ? 'arch' : 'mac' });
const request = () => ({ ...handshake(), kind: 'request', repo: 'git@github.com:pips/Epub-to-Mp3.git', commit, branch: 'feature/test', platform: 'flutter-linux', owner: 'arch', scope: ['Flutter reader'], acceptance: ['Regression passes'], authorization: 'Current user authorized focused validation', reply_to: { workspace: 'default', project: 'epubtomp3-mac' } });
function fixture(outputs, role = 'arch', settings = config) {
  const calls = [];
  const client = createClient({ config: settings, role, runner(command, args, options) {
    calls.push({ command, args, options });
    assert.ok(outputs.length, 'Unexpected command');
    const output = outputs.shift();
    return output?.status !== undefined || output?.error ? output : { status: 0, stdout: JSON.stringify(output) };
  } });
  return { client, calls };
}
const pending = body => ({ id, state: 'pending', body: JSON.stringify(body) });

test('Mac routes literal commands to Arch SSH; Arch uses local CLI and explicit scope', () => {
  const { client, calls } = fixture([[]], 'mac');
  assert.deepEqual(client.list('inbox'), []);
  assert.equal(calls[0].command, '/usr/bin/ssh');
  assert.deepEqual(calls[0].args.slice(0, 8), ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', 'arch', calls[0].args[7]]);
  assert.match(calls[0].args[7], /'message' 'list' '--workspace' 'default' '--project' 'epubtomp3-mac'/);
  assert.equal(calls[0].options.timeout, 15000);
  assert.match(calls[0].args[7], /'--limit' '200'/);
  const arch = fixture([[]]);
  arch.client.list('outbox');
  assert.equal(arch.calls[0].command, 'ai-memory');
  assert.deepEqual(arch.calls[0].args.slice(0, 7), ['message', 'list', '--workspace', 'default', '--project', 'Epub-to-Mp3', '--outbox']);
  assert.equal(arch.calls[0].args[arch.calls[0].args.indexOf('--limit') + 1], '200');
});

test('send carries body on stdin without executing shell text or substituting payload', () => {
  const body = { ...request(), scope: ["$(touch /tmp/never) ' `echo secret`\nreader"] };
  const { client, calls } = fixture([[], { id }], 'mac');
  assert.deepEqual(client.send(body), { id });
  assert.deepEqual(JSON.parse(calls[1].options.input), body);
  assert.doesNotMatch(calls[1].args.at(-1), /touch|echo secret/);
  assert.match(calls[1].args.at(-1), /'--from-project' 'epubtomp3-mac' '--to-workspace' 'default' '--to-project' 'Epub-to-Mp3'/);
});

test('POSIX quoting preserves malicious literal arguments and rejects host option injection', () => {
  assert.equal(posixQuote("a'b"), "'a'\\''b'");
  const command = commandFor(config, 'mac', ['message', "$(evil); 'abc'"]);
  assert.match(command.args.at(-1), /'\$\(evil\); '\\''abc'\\'''$/);
  for (const ssh_host of ['-oProxyCommand=evil', 'arch;evil', 'arch\nother']) {
    assert.throws(() => validateConfig({ ...config, ssh_host }), /SSH host/);
  }
});

test('request rejects incomplete identity, acceptance and authorization before invoking CLI', () => {
  for (const key of ['repo', 'commit', 'branch', 'platform', 'owner', 'scope', 'acceptance', 'authorization', 'reply_to']) {
    const body = request(); delete body[key];
    const { client, calls } = fixture([], 'mac');
    assert.throws(() => client.send(body));
    assert.equal(calls.length, 0);
  }
  for (const commit of ['abc', 'A'.repeat(40), 'g'.repeat(40)]) {
    assert.throws(() => validateEnvelope({ ...request(), commit }, { config, sender: 'mac', recipient: 'arch' }), /commit/);
  }
});

test('unsupported protocol, kind, foreign role and forged reply mailbox are rejected', () => {
  for (const patch of [{ protocol: 'other' }, { kind: 'execute-shell' }, { sender: 'arch' }, { recipient: 'mac' }, { reply_to: { workspace: 'default', project: 'other' } }]) {
    const { client, calls } = fixture([], 'mac');
    assert.throws(() => client.send({ ...request(), ...patch }));
    assert.equal(calls.length, 0);
  }
});

test('acknowledgement and result require explicit correlation and actual evidence', () => {
  const options = { config, sender: 'arch', recipient: 'mac' };
  const ack = { ...handshake('arch'), kind: 'acknowledgement', in_reply_to: id };
  validateEnvelope(ack, options);
  assert.throws(() => validateEnvelope({ ...ack, in_reply_to: undefined }, options), /in_reply_to/);
  const result = { ...ack, kind: 'result', status: 'passed', observed_commit: commit, environment: { os: 'Arch Linux' }, evidence: [{ command: 'flutter test', exit: 0 }] };
  validateEnvelope(result, options);
  for (const patch of [{ status: 'done' }, { observed_commit: 'short' }, { environment: {} }, { evidence: [] }]) {
    assert.throws(() => validateEnvelope({ ...result, ...patch }, options));
  }
});

test('array-valued identity cannot be coerced into scalar UUIDs or commits before mutation', () => {
  const ack = { ...handshake('arch'), kind: 'acknowledgement', in_reply_to: id };
  const result = { ...ack, kind: 'result', status: 'passed', observed_commit: commit, environment: 'Arch', evidence: ['verified'] };
  const malformed = [
    { ...request(), commit: [commit] },
    { ...ack, in_reply_to: [id] },
    { ...result, observed_commit: [commit] },
  ];
  for (const body of malformed) {
    const sender = fixture([], body.sender);
    assert.throws(() => sender.client.send(body));
    assert.equal(sender.calls.length, 0);
    const recipient = fixture([[pending(body)]], body.recipient);
    assert.throws(() => recipient.client.claim(id));
    assert.equal(recipient.calls.length, 1);
    const cancel = fixture([[pending(body)]], body.sender);
    assert.throws(() => cancel.client.cancel(id));
    assert.equal(cancel.calls.length, 1);
  }
  const settings = structuredClone(config);
  settings.roles.mac.project_id = [id];
  assert.throws(() => createClient({ config: settings, role: 'arch' }), /project_id/);
});

test('claim validates exact pending inbox envelope before popping that UUID once', () => {
  const { client, calls } = fixture([[pending(handshake())], { id, state: 'claimed' }]);
  assert.equal(client.claim(id).state, 'claimed');
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[1].args, ['message', 'pop', '--workspace', 'default', '--project', 'Epub-to-Mp3', '--id', id, '--json']);
});

test('cancel validates outbound direction before cancelling one exact ID, never all', () => {
  const { client, calls } = fixture([[pending(handshake('arch'))], { id, state: 'cancelled' }]);
  assert.equal(client.cancel(id).state, 'cancelled');
  assert.ok(calls[0].args.includes('--outbox'));
  assert.deepEqual(calls[1].args, ['message', 'cancel', '--workspace', 'default', '--project', 'Epub-to-Mp3', '--id', id, '--json']);
  assert.equal(calls.some(call => call.args.includes('--all')), false);
});

test('invalid IDs, missing/duplicate IDs, foreign bodies and terminal state never mutate', () => {
  const invalid = fixture([]);
  for (const action of ['claim', 'cancel']) {
    for (const value of [undefined, '', '--all', 'not-uuid']) assert.throws(() => invalid.client[action](value), /UUID/);
  }
  assert.equal(invalid.calls.length, 0);
  for (const output of [[], [pending(handshake()), pending(handshake())], [{ ...pending(handshake()), state: 'claimed' }], [{ ...pending(handshake()), body: 'untrusted text' }], [pending(handshake('arch'))], [pending({ ...handshake(), protocol: 'other' })]]) {
    const { client, calls } = fixture([output]);
    assert.throws(() => client.claim(id));
    assert.equal(calls.length, 1);
  }
});

test('known project UUID mismatch blocks mutation even when body roles match', () => {
  const settings = structuredClone(config);
  settings.roles.mac.project_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const { client, calls } = fixture([[{ ...pending(handshake()), from_project_id: id }]], 'arch', settings);
  assert.throws(() => client.claim(id), /provenance/);
  assert.equal(calls.length, 1);
});

test('cancel refuses inbound or foreign protocol mail without mutation', () => {
  for (const body of [handshake(), { ...handshake('arch'), protocol: 'other' }]) {
    const { client, calls } = fixture([[pending(body)]]);
    assert.throws(() => client.cancel(id));
    assert.equal(calls.length, 1);
  }
});

test('failed CLI preserves exact exit code and prevents all follow-up operations', () => {
  const { client, calls } = fixture([{ status: 37, stderr: 'denied' }]);
  assert.throws(() => client.claim(id), error => error.exitCode === 37 && /denied/.test(error.message));
  assert.equal(calls.length, 1);
});

test('malformed/nonarray list output cannot lead to a pop or cancellation', () => {
  for (const output of [{ status: 0, stdout: '{' }, { unexpected: [] }]) {
    const { client, calls } = fixture([output]);
    assert.throws(() => client.cancel(id), /JSON|array/);
    assert.equal(calls.length, 1);
  }
});

test('ambiguous send timeout never retries and requires reconciliation', () => {
  const { client, calls } = fixture([[], { status: null, error: { code: 'ETIMEDOUT' } }], 'mac');
  assert.throws(() => client.send(handshake()), /ambiguous.*Reconcile/);
  assert.equal(calls.length, 2);
});

test('pending send identity prevents duplicate sends even when unrelated content changes', () => {
  for (const body of [handshake(), request()]) {
    const { client, calls } = fixture([[pending(body)]], 'mac');
    assert.throws(() => client.send({ ...body, note: 'Changed prose must not duplicate work' }), error => error.message.includes(id));
    assert.equal(calls.length, 1);
  }
});

test('replies to distinct requests for the same task retain separate correlation identities', () => {
  const existing = { ...handshake('arch'), kind: 'acknowledgement', in_reply_to: id };
  const reply = { ...existing, in_reply_to: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' };
  const { client, calls } = fixture([[pending(existing)], { id }]);
  assert.deepEqual(client.send(reply), { id });
  assert.equal(calls.length, 2);
  const duplicate = fixture([[pending(existing)]]);
  assert.throws(() => duplicate.client.send(existing), /already pending/);
  assert.equal(duplicate.calls.length, 1);
});

test('unrelated, foreign and malformed pending messages do not block new work', () => {
  const outbox = [pending({ ...request(), task_id: 'OTHER' }), pending({ ...request(), protocol: 'other' }),
    pending(handshake('arch')), { ...pending(handshake()), body: '{' }];
  const { client, calls } = fixture([outbox, { id }], 'mac');
  assert.deepEqual(client.send(request()), { id });
  assert.equal(calls.length, 2);
});

test('a saturated outbox cannot hide a duplicate beyond the CLI listing limit', () => {
  const { client, calls } = fixture([Array.from({ length: 200 }, (_, i) => pending({ ...handshake(), task_id: `OTHER-${i}` }))], 'mac');
  assert.throws(() => client.send(handshake()), /inspection limit/);
  assert.equal(calls.length, 1);
});

test('failed send or malformed acknowledgement preserves status and requires reconciliation', () => {
  for (const failure of [{ status: 17, stderr: 'SSH disconnected' }, { status: 0, stdout: '{' }]) {
    const { client, calls } = fixture([[], failure], 'mac');
    assert.throws(() => client.send(handshake()), error => /Reconcile the outbox/.test(error.message) && (failure.status === 0 || error.exitCode === 17));
    assert.equal(calls.length, 2);
  }
});

test('pop race returns original failure rather than retrying or claiming another message', () => {
  const { client, calls } = fixture([[pending(handshake())], { status: 9, stderr: 'already claimed' }]);
  assert.throws(() => client.claim(id), error => error.exitCode === 9);
  assert.equal(calls.length, 2);
});
