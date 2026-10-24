import { describe, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({
  default: vi.fn(),
  ConversionSession: vi.fn(),
  inspect_epub: vi.fn(),
}));
import { installFaberArtifacts, type FaberInstallerIO } from './BrowserConversionClient';
const hashes = [
  '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7',
  '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f',
];
function fixtureBlob(config: boolean): Blob {
  const blob = new Blob(['fixture']);
  Object.defineProperty(blob, 'size', { value: config ? 4_855 : 63_201_294 });
  Object.defineProperty(blob, 'arrayBuffer', {
    value: async () => new Uint8Array([config ? 1 : 0]).buffer,
  });
  return blob;
}
function fixtureIO(): FaberInstallerIO {
  const files = new Map<string, Blob>();
  return {
    fetchArtifact: vi.fn(async (url) => fixtureBlob(url.includes('.json'))),
    writeFile: vi.fn(async (name, blob) => {
      files.set(name, blob);
    }),
    readFile: vi.fn(async (name) => {
      const blob = files.get(name);
      if (!blob) throw new Error('Missing staged file');
      return blob;
    }),
    removeFile: vi.fn(async (name) => {
      files.delete(name);
    }),
    digest: vi.fn(
      async (data) =>
        Uint8Array.from(hashes[new Uint8Array(data)[0]].match(/../g) ?? [], (value) =>
          parseInt(value, 16),
        ).buffer,
    ),
  };
}
describe('explicit browser model installation', () => {
  it('restores both previous artifacts when publication fails after the first replacement', async () => {
    const io = fixtureIO();
    const previousModel = new Blob(['previous model']);
    const previousConfig = new Blob(['previous config']);
    const files = new Map<string, Blob>([
      ['pt_BR-faber-medium.onnx', previousModel],
      ['pt_BR-faber-medium.onnx.json', previousConfig],
    ]);
    io.readFile = vi.fn(async (name) => {
      const value = files.get(name);
      if (!value) throw new Error('Missing');
      return value;
    });
    let interrupted = false;
    io.writeFile = vi.fn(async (name, blob) => {
      if (name === 'pt_BR-faber-medium.onnx.json' && !interrupted) {
        interrupted = true;
        throw new Error('Publication failed');
      }
      files.set(name, blob);
    });
    io.removeFile = vi.fn(async (name) => {
      files.delete(name);
    });
    await expect(installFaberArtifacts(io)).rejects.toThrow('Publication failed');
    expect(files.get('pt_BR-faber-medium.onnx')).toBe(previousModel);
    expect(files.get('pt_BR-faber-medium.onnx.json')).toBe(previousConfig);
  });
  it('awaits staged writes before publishing the verified model pair', async () => {
    const io = fixtureIO();
    let release!: () => void;
    let started!: () => void;
    const writing = new Promise<void>((resolve) => {
      started = resolve;
    });
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const originalWrite = io.writeFile;
    io.writeFile = vi.fn(async (name, blob) => {
      if (name.startsWith('.faber-install-') && name.endsWith('.onnx')) {
        started();
        await gate;
      }
      await originalWrite(name, blob);
    });
    const installation = installFaberArtifacts(io);
    await writing;
    expect(io.fetchArtifact).toHaveBeenCalledTimes(1);
    expect(io.readFile).not.toHaveBeenCalledWith(expect.stringMatching(/^\.faber-install-/));
    release();
    await installation;
    expect(io.writeFile).toHaveBeenCalledWith('pt_BR-faber-medium.onnx', expect.any(Blob));
    expect(io.writeFile).toHaveBeenCalledWith('pt_BR-faber-medium.onnx.json', expect.any(Blob));
    expect(io.removeFile).toHaveBeenCalledTimes(2);
  });
  it('preserves an already verified installation without fetch, writes or removals', async () => {
    const io = fixtureIO();
    io.readFile = vi.fn(async (name) => fixtureBlob(name.endsWith('.json')));
    io.writeFile = vi.fn(async () => {
      throw new DOMException('Quota exceeded', 'QuotaExceededError');
    });
    await installFaberArtifacts(io);
    expect(io.readFile).toHaveBeenCalledWith('pt_BR-faber-medium.onnx');
    expect(io.readFile).toHaveBeenCalledWith('pt_BR-faber-medium.onnx.json');
    expect(io.fetchArtifact).not.toHaveBeenCalled();
    expect(io.writeFile).not.toHaveBeenCalled();
    expect(io.removeFile).not.toHaveBeenCalled();
  });

  it('cleans only staging on invalid downloads and leaves existing installations intact', async () => {
    const io = fixtureIO();
    io.digest = vi.fn(async () => new ArrayBuffer(32));
    await expect(installFaberArtifacts(io)).rejects.toThrow('checksum validation failed');
    expect(io.writeFile).not.toHaveBeenCalled();
    expect(io.removeFile).toHaveBeenCalledTimes(2);
    expect(io.removeFile).not.toHaveBeenCalledWith('pt_BR-faber-medium.onnx');
    expect(io.removeFile).not.toHaveBeenCalledWith('pt_BR-faber-medium.onnx.json');
  });
});
