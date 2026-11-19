// Test inputs for the production React client. Its own Rust encoder generates
// MP3 frames and its production adapter captures the catalog identity/receipts.
import initialize, { encode_pcm_f32_mp3 } from "../../../../web/src/wasm/converter_wasm.js"

export async function verifyBrowserModel() {}
export function cancelPiper() {}

export async function synthesizePiperAudio(text, modelId, modelRevision, voice) {
  await initialize()
  const sampleRate = 22050
  const tone = Float32Array.from({ length: sampleRate / 5 }, (_, index) => 0.2 * Math.sin(2 * Math.PI * 660 * index / sampleRate))
  return { audio: encode_pcm_f32_mp3(tone, sampleRate), modelRevision, voice: voice ?? "0" }
}
