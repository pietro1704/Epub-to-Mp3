// @vitest-environment node
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'vite';
import { expect, it } from 'vitest';
import { onnxRuntimeModule } from '../../plugins/onnxRuntimeModule.ts';

it('serves the ONNX runtime import as JavaScript without opening unrelated public imports', async () => {
  const root = await mkdtemp(join(tmpdir(), 'onnx-vite-'));
  await mkdir(join(root, 'public/tts'), { recursive: true });
  const source = "export default function createRuntime() { return 'runtime'; }";
  await writeFile(join(root, 'public/tts/ort-wasm-simd-threaded.mjs'), source);
  await writeFile(join(root, 'public/private.mjs'), "export default 'private';");
  const server = await createServer({
    plugins: [onnxRuntimeModule()],
    configFile: false,
    root,
    publicDir: 'public',
    logLevel: 'silent',
    server: { host: '127.0.0.1', port: 0 },
  });
  try {
    await server.listen();
    const base = server.resolvedUrls!.local[0];
    const response = await fetch(`${base}tts/ort-wasm-simd-threaded.mjs?import`);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('javascript');
    expect(await response.text()).toBe(source);
    expect((await fetch(`${base}private.mjs?import`)).status).toBe(500);
    await rm(join(root, 'public/tts/ort-wasm-simd-threaded.mjs'));
    expect((await fetch(`${base}tts/ort-wasm-simd-threaded.mjs?import`)).status).toBe(404);
  } finally {
    await server.close();
    await rm(root, { recursive: true, force: true });
  }
});
