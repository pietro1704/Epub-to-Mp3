import initWasm, { tts_request_cache_material_v2 } from '../wasm/converter_wasm';
import type { StoredBrowserAudio, StoredBrowserJob } from './BrowserJobStore';

type Source = Pick<StoredBrowserJob, 'document' | 'preferences' | 'language'>;
async function bytes(blob: Blob): Promise<ArrayBuffer> {
  if (blob.arrayBuffer) return blob.arrayBuffer();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.readAsArrayBuffer(blob);
  });
}
async function digest(value: ArrayBuffer): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', value)), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
}

/** Same Rust identity schema, sealed against source/selection/byte changes. */
export async function sealBrowserAudio(
  source: Source,
  audio: StoredBrowserAudio,
): Promise<string | undefined> {
  if (!audio.ttsReceipts?.length) return undefined; // Legacy captured artifacts retain their original contract.
  if (
    audio.ttsReceipts.some(
      (receipt, index) =>
        receipt.version !== 2 ||
        receipt.format.encoding !== 'mp3' ||
        !receipt.session_id ||
        !receipt.identity.reusable ||
        receipt.source_index !== audio.chapterIndex ||
        (index > 0 && receipt.segment_index !== audio.ttsReceipts![index - 1].segment_index + 1),
    )
  )
    throw new Error('Audio has an opaque or conflicting source identity');
  const sessions = new Set(audio.ttsReceipts.map((receipt) => receipt.session_id));
  if (sessions.size !== 1) throw new Error('Audio mixes retired synthesis sessions');
  await initWasm();
  const material = tts_request_cache_material_v2(
    JSON.stringify([
      source.document,
      audio.chapterIndex,
      audio.textOffset ?? 0,
      audio.chunks ?? null,
    ]),
    source.language,
    JSON.stringify(source.preferences),
    JSON.stringify(audio.ttsReceipts.map((receipt) => JSON.stringify(receipt))),
  );
  const materialHash = await digest(new TextEncoder().encode(material).buffer as ArrayBuffer);
  return `${materialHash}:${await digest(await bytes(audio.blob))}`;
}

export async function browserAudioMatches(
  source: Source,
  audio: StoredBrowserAudio,
): Promise<boolean> {
  if (!audio.ttsReceipts?.length)
    return (
      !audio.cacheIdentity &&
      !source.preferences.primary.session &&
      !source.preferences.secondary?.session
    );
  if (!audio.cacheIdentity) return false;
  try {
    return (await sealBrowserAudio(source, audio)) === audio.cacheIdentity;
  } catch {
    return false;
  }
}
