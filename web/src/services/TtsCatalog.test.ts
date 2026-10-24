import { describe, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({ default: vi.fn() }));
import { browserArtifacts, browserSelections, type TtsCatalog } from './TtsCatalog';

describe('descriptor-driven browser selection', () => {
  it('adds two compatible models through configuration and retains runtime and artifact identity', () => {
    const catalog: TtsCatalog = {
      version: 2,
      models: ['a', 'b'].map((id) => ({
        id,
        engine: 'piper',
        revision: `sha-${id}`,
        runtime_available: true,
        artifacts: [
          { name: 'model.onnx', url: `https://example.com/${id}`, sha256: `sha-${id}`, bytes: 10 },
        ],
      })),
      providers: [
        {
          provider: 'piper',
          runtime: 'piper-web',
          revision: '1',
          targets: ['web'],
          capabilities: { audio_bytes: true, online: false },
        },
      ],
    };
    const selections = browserSelections(catalog);
    expect(selections.map((selection) => selection.model_id)).toEqual(['a', 'b']);
    expect(selections[1].session).toMatchObject({ runtime: 'piper-web', model_revision: 'sha-b' });
    expect(browserArtifacts(catalog.models[1])[0]).toMatchObject({
      name: 'b.onnx',
      sha256: 'sha-b',
    });
    catalog.providers[0].capabilities.audio_bytes = false;
    expect(browserSelections(catalog)).toEqual([]);
  });
});
