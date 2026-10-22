import {
  faberArtifacts,
  verifyBrowserFaber,
  invalidateBrowserFaberVerification,
} from './BrowserModelIntegrity';

export const browserVoiceId = 'pt_BR-faber-medium';
export const browserWasmPaths = {
  onnxWasm: '/tts/',
  piperData: '/tts/piper_phonemize.data',
  piperWasm: '/tts/piper_phonemize.wasm',
};
export async function installedBrowserVoices(): Promise<string[]> {
  return (await import('@mintplex-labs/piper-tts-web')).stored();
}
let modelInstallation: Promise<void> | undefined;
export async function installBrowserFaber(): Promise<void> {
  if (modelInstallation) return modelInstallation;
  modelInstallation = (async () => {
    const directory = await (
      await navigator.storage.getDirectory()
    ).getDirectoryHandle('piper', { create: true });
    await installFaberArtifacts({
      fetchArtifact: async (url) => {
        const response = await fetch(url);
        if (!response.ok) throw new Error(`Model download failed: HTTP ${response.status}`);
        return response.blob();
      },
      writeFile: async (name, blob) => {
        const writer = await (
          await directory.getFileHandle(name, { create: true })
        ).createWritable();
        try {
          await writer.write(blob);
          await writer.close();
        } catch (error) {
          try {
            await writer.abort();
          } catch {
            /* Writer may already be closed. */
          }
          throw error;
        }
      },
      readFile: async (name) => (await directory.getFileHandle(name)).getFile(),
      removeFile: (name) => directory.removeEntry(name),
      digest: (data) => crypto.subtle.digest('SHA-256', data),
    });
    await verifyBrowserFaber(directory);
  })();
  try {
    await modelInstallation;
  } finally {
    modelInstallation = undefined;
  }
}
export interface FaberInstallerIO {
  fetchArtifact(url: string): Promise<Blob>;
  writeFile(name: string, blob: Blob): Promise<void>;
  readFile(name: string): Promise<Blob>;
  removeFile(name: string): Promise<void>;
  digest(data: ArrayBuffer): Promise<ArrayBuffer>;
}
/** Stage and verify the entire pair before publishing; await every OPFS write. */
export async function installFaberArtifacts(io: FaberInstallerIO): Promise<void> {
  // Reinstalling an already verified voice must never risk replacing its files.
  try {
    let complete = true;
    for (const artifact of faberArtifacts) {
      const existing = await io.readFile(artifact.name);
      if (existing.size !== artifact.bytes) {
        complete = false;
        break;
      }
      const digest = await io.digest(await existing.arrayBuffer());
      const hash = Array.from(new Uint8Array(digest), (byte) =>
        byte.toString(16).padStart(2, '0'),
      ).join('');
      if (hash !== artifact.sha256) {
        complete = false;
        break;
      }
    }
    if (complete) return;
  } catch {
    /* A missing or unreadable pair still requires explicit installation. */
  }
  const prefix = `.faber-install-${crypto.randomUUID()}`;
  const staged = faberArtifacts.map((artifact) => `${prefix}-${artifact.name}`);
  let publishing = false;
  try {
    for (const [index, artifact] of faberArtifacts.entries()) {
      const blob = await io.fetchArtifact(
        `https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/${artifact.name}?download=true`,
      );
      const digest = await io.digest(await blob.arrayBuffer());
      const hash = Array.from(new Uint8Array(digest), (byte) =>
        byte.toString(16).padStart(2, '0'),
      ).join('');
      if (blob.size !== artifact.bytes || hash !== artifact.sha256)
        throw new Error(`Faber medium checksum validation failed: ${artifact.name}`);
      await io.writeFile(staged[index], blob);
    }
    publishing = true;
    invalidateBrowserFaberVerification();
    for (const [index, artifact] of faberArtifacts.entries())
      await io.writeFile(artifact.name, await io.readFile(staged[index]));
  } catch (error) {
    if (publishing) {
      for (const artifact of faberArtifacts) {
        try {
          await io.removeFile(artifact.name);
        } catch {
          /* Only this model's incomplete published pair. */
        }
      }
    }
    throw error;
  } finally {
    for (const name of staged) {
      try {
        await io.removeFile(name);
      } catch {
        /* A failed download may not create its staging file. */
      }
    }
  }
}

export function pendingBrowserModelInstallation(): Promise<void> | undefined {
  return modelInstallation;
}
