import { copyFile, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export async function prepareTtsRuntime(root) {
  const destination = resolve(root, "public/tts");
  await mkdir(destination, { recursive: true });
  for (const name of ["piper_phonemize.data", "piper_phonemize.wasm"]) {
    await copyFile(resolve(root, "node_modules/@diffusionstudio/piper-wasm/build", name), resolve(destination, name));
  }
  // ONNX Runtime 1.30 loads its CPU WASM through a companion ES module.
  for (const name of ["ort-wasm-simd-threaded.mjs", "ort-wasm-simd-threaded.wasm"]) {
    await copyFile(resolve(root, "node_modules/onnxruntime-web/dist", name), resolve(destination, name));
  }
  for (const name of ["ort-wasm.wasm", "ort-wasm-threaded.wasm", "ort-wasm-simd.wasm", "ort-training-wasm-simd.wasm", "ort-wasm-simd.jsep.wasm", "ort-wasm-simd-threaded.jsep.wasm"]) {
    await rm(resolve(destination, name), { force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await prepareTtsRuntime(resolve(import.meta.dirname, ".."));
}
