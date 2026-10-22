export const faberArtifacts = [
  {
    name: 'pt_BR-faber-medium.onnx',
    sha256: '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7',
    bytes: 63_201_294,
  },
  {
    name: 'pt_BR-faber-medium.onnx.json',
    sha256: '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f',
    bytes: 4_855,
  },
] as const;
const verifiedArtifacts = new Map<string, string>();
/** Verify the same immutable artifact checksums as the Rust model catalog. */
interface ArtifactDirectory {
  getFileHandle(name: string): Promise<{ getFile(): Promise<File> }>;
  removeEntry(name: string): Promise<void>;
}
export async function verifyBrowserFaber(
  directory?: ArtifactDirectory,
  digestSHA256: (data: ArrayBuffer) => Promise<ArrayBuffer> = (data) =>
    crypto.subtle.digest('SHA-256', data),
): Promise<void> {
  const artifacts =
    directory ?? (await (await navigator.storage.getDirectory()).getDirectoryHandle('piper'));
  for (const artifact of faberArtifacts) {
    let file: File;
    try {
      file = await (await artifacts.getFileHandle(artifact.name)).getFile();
    } catch {
      throw new Error('Faber medium is incomplete. Install the model before converting.');
    }
    const identity = `${file.size}:${file.lastModified}`;
    if (verifiedArtifacts.get(artifact.name) === identity) continue;
    const digest = await digestSHA256(await file.arrayBuffer());
    const hash = Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, '0'),
    ).join('');
    if (file.size !== artifact.bytes || hash !== artifact.sha256) {
      verifiedArtifacts.clear();
      for (const corrupted of faberArtifacts) {
        try {
          await artifacts.removeEntry(corrupted.name);
        } catch {
          /* Preserve unrelated models. */
        }
      }
      throw new Error(
        'Faber medium checksum validation failed. Corrupt model files were removed; reinstall the model.',
      );
    }
    verifiedArtifacts.set(artifact.name, identity);
  }
}

export function invalidateBrowserFaberVerification(): void {
  verifiedArtifacts.clear();
}
