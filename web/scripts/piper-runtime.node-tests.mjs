import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { BrowserPiperRuntime } from '../src/services/BrowserPiperRuntime.ts';
import { initSync, encode_pcm_f32_mp3 } from '../src/wasm/converter_wasm.js';

const require = createRequire(import.meta.url);
const phonemizer =
  dirname(require.resolve('@diffusionstudio/piper-wasm/build/piper_phonemize.js')) + '/';
const onnxWasm = dirname(require.resolve('onnxruntime-web/wasm')) + '/';
initSync({ module: readFileSync(new URL('../src/wasm/converter_wasm_bg.wasm', import.meta.url)) });

// Independent ONNX protobuf fixture: Constant PCM output plus the three typed
// Piper inputs. Both the phonemizer and inference session are real dependencies;
// these synthetic tones test the adapter contract, not trained-model quality.
const varint = (value) => {
  const bytes = [];
  do {
    let byte = value & 127;
    value >>>= 7;
    if (value) byte |= 128;
    bytes.push(byte);
  } while (value);
  return Buffer.from(bytes);
};
const integer = (field, value) => Buffer.concat([varint(field << 3), varint(value)]);
const message = (field, bytes) => {
  bytes = Buffer.from(bytes);
  return Buffer.concat([varint((field << 3) | 2), varint(bytes.length), bytes]);
};
function typedValue(name, type, dimensions) {
  const shape = Buffer.concat(
    dimensions.map((dimension) =>
      message(1, typeof dimension === 'string' ? message(2, dimension) : integer(1, dimension)),
    ),
  );
  return Buffer.concat([
    message(1, name),
    message(2, message(1, Buffer.concat([integer(1, type), message(2, shape)]))),
  ]);
}
function toneModel(frequency) {
  const samples = Buffer.alloc(4800 * 4);
  for (let index = 0; index < 4800; index++)
    samples.writeFloatLE(Math.sin((index * frequency * 2 * Math.PI) / 24000) * 0.2, index * 4);
  const tensor = Buffer.concat([
    integer(1, 1),
    integer(1, 1),
    integer(1, 4800),
    integer(2, 1),
    message(9, samples),
  ]);
  const attribute = Buffer.concat([message(1, 'value'), message(5, tensor), integer(20, 4)]);
  const node = Buffer.concat([message(2, 'output'), message(4, 'Constant'), message(5, attribute)]);
  const graph = Buffer.concat([
    message(1, node),
    message(2, 'piper-contract-tone'),
    message(11, typedValue('input', 7, [1, 'tokens'])),
    message(11, typedValue('input_lengths', 7, [1])),
    message(11, typedValue('scales', 1, [3])),
    message(12, typedValue('output', 1, [1, 1, 4800])),
  ]);
  return Buffer.concat([
    integer(1, 8),
    message(2, 'epubtomp3-contract-fixture'),
    message(7, graph),
    message(8, integer(2, 13)),
  ]);
}
const config = Buffer.from(
  JSON.stringify({
    audio: { sample_rate: 24000 },
    espeak: { voice: 'pt-br' },
    inference: { noise_scale: 0.667, length_scale: 1, noise_w: 0.8 },
    speaker_id_map: {},
  }),
);
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const buffer = (bytes) => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);

test('real Piper phonemizer and ONNX execute two configured fixture models without model downloads', async () => {
  const files = new Map();
  for (const [id, frequency] of [
    ['fixture-a', 220],
    ['fixture-b', 440],
  ]) {
    files.set(`${id}.onnx`, toneModel(frequency));
    files.set(`${id}.onnx.json`, config);
  }
  const previousNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  const previousFetch = globalThis.fetch;
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: {
      storage: {
        getDirectory: async () => ({
          getDirectoryHandle: async (name) => {
            assert.equal(name, 'piper');
            return {
              getFileHandle: async (name) => {
                const bytes = files.get(name);
                if (!bytes) throw new Error('Model is not installed');
                return { getFile: async () => ({ arrayBuffer: async () => buffer(bytes) }) };
              },
            };
          },
        }),
      },
    },
  });
  globalThis.fetch = async (input) => {
    const path = String(input);
    assert.ok(!/^https?:/.test(path), 'Inference must never download a model');
    const absolute = resolve(path);
    assert.ok(absolute.startsWith(onnxWasm) || absolute.startsWith(phonemizer));
    return new Response(readFileSync(absolute), {
      headers: { 'Content-Type': 'application/wasm' },
    });
  };
  try {
    const outputs = [];
    for (const id of ['fixture-a', 'fixture-b']) {
      const revision = `${sha(files.get(`${id}.onnx`))}:${sha(config)}`;
      const session = await BrowserPiperRuntime.prepare(id, revision, { onnxWasm, phonemizer });
      const audio = await session.synthesize('Olá, este texto passa pelo fonemizador real.');
      assert.equal(audio.modelRevision, revision);
      assert.equal(audio.samples.length, 4800);
      const mp3 = encode_pcm_f32_mp3(audio.samples, audio.sampleRate);
      const probe = spawnSync(
        'ffprobe',
        [
          '-v',
          'error',
          '-show_entries',
          'stream=codec_name,sample_rate,channels',
          '-of',
          'json',
          '-i',
          'pipe:0',
        ],
        { input: mp3 },
      );
      assert.equal(probe.status, 0, probe.stderr.toString());
      assert.deepEqual(JSON.parse(probe.stdout).streams[0], {
        codec_name: 'mp3',
        sample_rate: '24000',
        channels: 1,
      });
      outputs.push(Buffer.from(mp3));
      await assert.rejects(session.synthesize('Olá', 'missing-speaker'), /Voice is unavailable/);
      await session.dispose();
    }
    assert.notDeepEqual(outputs[0], outputs[1]);
    await assert.rejects(
      BrowserPiperRuntime.prepare('missing-model', undefined, { onnxWasm, phonemizer }),
      /not installed/,
    );
    await assert.rejects(
      BrowserPiperRuntime.prepare('fixture-a', 'wrong-revision', { onnxWasm, phonemizer }),
      /revision changed/,
    );
    for (const invalid of [
      '../escape',
      '.',
      '..',
      'nested/path',
      'nested\\path',
      'fixture\x00a',
      'fixture\x1fa',
    ]) {
      await assert.rejects(BrowserPiperRuntime.prepare(invalid), /Invalid installed model ID/);
    }
  } finally {
    globalThis.fetch = previousFetch;
    if (previousNavigator) Object.defineProperty(globalThis, 'navigator', previousNavigator);
    else delete globalThis.navigator;
  }
});
