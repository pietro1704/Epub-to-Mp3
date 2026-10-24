import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  ConversionSession,
  initSync,
  tts_catalog_json_v2,
  encode_pcm_f32_mp3,
} from '../src/wasm/converter_wasm.js';

initSync({ module: readFileSync(new URL('../src/wasm/converter_wasm_bg.wasm', import.meta.url)) });
const catalog = JSON.parse(tts_catalog_json_v2());
const adapter = catalog.providers.find((provider) => provider.runtime === 'piper-web');
const model = (id) => catalog.models.find((model) => model.id === id);
const selection = (id) => ({
  engine: 'piper',
  model_id: id,
  voice: null,
  session: {
    version: 2,
    provider: 'piper',
    runtime: 'piper-web',
    model_id: id,
    model_revision: model(id).revision,
    voice: null,
    options: {},
  },
});
const primary = selection('pt_BR-faber-medium');
const secondary = selection('piper-default');
const policy = () => ({ primary, secondary: null, allow_online_fallback: false });
const chapters = () => [{ index: 16, text: 'Uma frase conhecida.' }];
const create = (preferences = policy(), language = 'pt-BR') =>
  new ConversionSession(JSON.stringify(chapters()), JSON.stringify(preferences), language);
const audio = encode_pcm_f32_mp3(
  Float32Array.from(
    { length: 4800 },
    (_, index) => Math.sin((index * 220 * 2 * Math.PI) / 24000) * 0.2,
  ),
  24000,
);
function receipt(session, selected, segment = 0) {
  return {
    version: 2,
    session_id: JSON.parse(session.next_segment()).session_id,
    source_index: 16,
    segment_index: segment,
    format: { encoding: 'mp3' },
    identity: {
      selection: { ...selected.session, voice: '0' },
      runtime_revision: adapter.revision,
      artifacts: Object.fromEntries(
        model(selected.model_id).artifacts.map((artifact) => [artifact.name, artifact.sha256]),
      ),
      reusable: true,
    },
  };
}

test('real WASM rejects low primary/secondary selections and marks low catalog entries unavailable', () => {
  for (const id of ['pt_BR-edresson-low', 'en_US-lessac-low']) {
    assert.equal(model(id).runtime_available, false);
    assert.throws(() => create({ ...policy(), primary: selection(id) }), /low quality/);
    assert.throws(() => create({ ...policy(), secondary: selection(id) }), /low quality/);
  }
});

test('WASM rejects stale source, runtime, artifact, format and model receipts before accepting audio', () => {
  const session = create();
  try {
    assert.throws(() => session.accept_audio(audio), /require an audio receipt/);
    for (const mutate of [
      (value) => {
        value.session_id = 'retired-session';
      },
      (value) => {
        value.source_index = 17;
      },
      (value) => {
        value.segment_index = 1;
      },
      (value) => {
        value.identity.runtime_revision = 'stale';
      },
      (value) => {
        value.identity.selection.model_id = secondary.model_id;
      },
      (value) => {
        value.identity.artifacts['model.onnx'] = 'wrong-hash';
      },
      (value) => {
        value.format.encoding = 'wav_pcm16';
      },
    ]) {
      const invalid = receipt(session, primary);
      mutate(invalid);
      assert.throws(() => session.accept_audio_v2(audio, JSON.stringify(invalid)));
      assert.equal(JSON.parse(session.next_segment()).index, 0);
    }
    assert.equal(session.accept_audio_v2(audio, JSON.stringify(receipt(session, primary))), true);
    assert.deepEqual(session.chapter_audio(), audio);
  } finally {
    session.free();
  }
});

test('a replacement session rejects a retired receipt even for the same text, model and segment', () => {
  const retired = create();
  const staleReceipt = receipt(retired, primary);
  retired.cancel();
  retired.free();
  const replacement = create();
  try {
    assert.notEqual(JSON.parse(replacement.next_segment()).session_id, staleReceipt.session_id);
    assert.throws(
      () => replacement.accept_audio_v2(audio, JSON.stringify(staleReceipt)),
      /pending segment/,
    );
    assert.equal(JSON.parse(replacement.next_segment()).index, 0);
  } finally {
    replacement.free();
  }
});

test('WASM shares native recovery counters across restart without committing a cancelled fallback', () => {
  const preferences = { ...policy(), secondary };
  let session = create(preferences);
  try {
    for (let failure = 0; failure < 2; failure++) {
      session.provider_failed();
      assert.equal(JSON.parse(session.next_segment()).selection.model_id, secondary.model_id);
      session.accept_audio_v2(audio, JSON.stringify(receipt(session, secondary)));
      session.chapter_audio();
      const state = session.policy_state_json();
      session.free();
      session = create(preferences);
      session.restore_policy_state_json(state);
      assert.throws(() => session.restore_policy_state_json(state));
    }
    const before = session.policy_state_json();
    assert.throws(() => session.provider_failed(), /three consecutive/);
    assert.equal(session.policy_state_json(), before);
    const pendingReceipt = receipt(session, primary);
    session.cancel();
    assert.throws(
      () => session.accept_audio_v2(audio, JSON.stringify(pendingReceipt)),
      /cancelled/,
    );
    assert.throws(() => session.provider_failed(), /cancelled/);
    assert.equal(session.policy_state_json(), before);
  } finally {
    session.free();
  }
});

test('versioned browser selection rejects incompatible languages and listening-only export', () => {
  assert.throws(() => create(policy(), 'en-US'), /does not support this language/);
  assert.throws(
    () => create({ ...policy(), primary: { engine: 'system', model_id: null, voice: null } }),
    /no browser audio-byte runtime/,
  );
  assert.throws(() => encode_pcm_f32_mp3(new Float32Array([Number.NaN]), 24000), /Invalid/);
});

test('app recovery uses a browser clock instead of unsupported WASM system time', () => {
  const session = create({ ...policy(), policy_version: 2, secondary });
  try {
    session.restore_policy_state_json(
      JSON.stringify({ consecutive_failures: 2, primary_retry_at_ms: Date.now() + 60000 }),
    );
    assert.equal(JSON.parse(session.next_segment()).selection.model_id, secondary.model_id);
    assert.equal(JSON.parse(session.next_segment()).fallback_used, true);
    session.cancel();
    assert.throws(() => session.chapter_audio(), /cancelled/);
  } finally {
    session.free();
  }
});

test('Unicode listening intent gates time-based prefetch and rejects stale feedback and receipts', () => {
  const sources = [
    { index: 16, text: 'á🙂 Selected words.' },
    { index: 17, text: 'Next chapter.' },
  ];
  const session = new ConversionSession(JSON.stringify(sources), JSON.stringify(policy()), 'pt-BR');
  const position = (chapter, offset) =>
    session.set_listening_position_json_v2(
      JSON.stringify({ version: 2, chapter_index: chapter, text_offset: offset }),
    );
  const feedback = (generation, remaining) =>
    session.playback_feedback_json_v2(
      JSON.stringify({
        version: 2,
        generation,
        chapter_index: 16,
        remaining_audio_seconds: remaining,
        playback_rate: 2,
      }),
    );
  try {
    position(16, 3);
    assert.equal(JSON.parse(session.next_segment()).text, 'Selected words.');
    const stale = receipt(session, primary);
    const oldGeneration = Number(session.listening_generation_v2());
    position(16, 4);
    assert.throws(() => session.accept_audio_v2(audio, JSON.stringify(stale)), /pending segment/);
    assert.throws(() => feedback(oldGeneration, 0), /old chapter/);
    assert.throws(() => position(16, Array.from(sources[0].text).length), /chapter end/);
    const generation = Number(session.listening_generation_v2());
    session.observe_generation_v2(8, 480);
    session.skip_cached_chapter_v2(16);
    feedback(generation, 30);
    assert.equal(JSON.parse(session.next_segment()).waiting, true);
    feedback(generation, 20);
    assert.equal(JSON.parse(session.next_segment()).chapter, 17);
    session.skip_cached_chapter_v2(17);
    position(16, 0);
    assert.equal(JSON.parse(session.next_segment()).chapter, 16);
    session.skip_cached_chapter_v2(16);
    assert.equal(JSON.parse(session.next_segment()).waiting, true);
    feedback(Number(session.listening_generation_v2()), 0);
    assert.equal(JSON.parse(session.next_segment()).chapter, 17);
  } finally {
    session.free();
  }
});
