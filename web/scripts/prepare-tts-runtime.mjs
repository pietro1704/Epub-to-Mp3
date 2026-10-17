import { copyFile, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "..");
const destination = resolve(root, "public/tts");
await mkdir(destination, { recursive: true });
for (const name of ["piper_phonemize.data", "piper_phonemize.wasm"]) {
  await copyFile(resolve(root, "node_modules/@diffusionstudio/piper-wasm/build", name), resolve(destination, name));
}
// Piper uses the CPU WASM provider. Keep SIMD/thread fallbacks for supported
// browsers, without shipping unused training or WebGPU/WebNN runtimes.
for (const name of ["ort-wasm.wasm", "ort-wasm-threaded.wasm", "ort-wasm-simd.wasm", "ort-wasm-simd-threaded.wasm"]) {
  await copyFile(resolve(root, "node_modules/onnxruntime-web/dist", name), resolve(destination, name));
}
for (const name of ["ort-training-wasm-simd.wasm", "ort-wasm-simd.jsep.wasm", "ort-wasm-simd-threaded.jsep.wasm"]) {
  await rm(resolve(destination, name), { force: true });
}
