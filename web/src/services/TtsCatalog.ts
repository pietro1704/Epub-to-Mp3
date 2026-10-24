import * as bindings from '../wasm/converter_wasm';
import type { TtsSelection } from '../types/conversion';

export interface TtsArtifact {
  name: string;
  url: string;
  sha256: string;
  bytes: number;
}
export interface TtsCatalogModel {
  id: string;
  engine: string;
  revision: string;
  artifacts: TtsArtifact[];
  runtime_available: boolean;
}
export interface TtsCatalog {
  version: 2;
  models: TtsCatalogModel[];
  providers: Array<{
    provider: string;
    runtime: string;
    revision: string;
    targets: string[];
    capabilities: { audio_bytes: boolean; online: boolean };
  }>;
}
let catalog: Promise<TtsCatalog> | undefined;
export function loadTtsCatalog(): Promise<TtsCatalog> {
  catalog ??= (async () => {
    await bindings.default();
    if (!('tts_catalog_json_v2' in bindings) || typeof bindings.tts_catalog_json_v2 !== 'function')
      throw new Error('The embedded converter does not support the version 2 TTS catalog.');
    const json: unknown = bindings.tts_catalog_json_v2();
    if (typeof json !== 'string') throw new Error('Invalid TTS catalog');
    const decoded = JSON.parse(json) as TtsCatalog;
    if (
      decoded.version !== 2 ||
      !Array.isArray(decoded.models) ||
      !Array.isArray(decoded.providers)
    )
      throw new Error('Unsupported TTS catalog version');
    return decoded;
  })().catch((error: unknown) => {
    catalog = undefined;
    throw error;
  });
  return catalog;
}
export function browserSelections(catalog: TtsCatalog): TtsSelection[] {
  return catalog.models.flatMap((model) => {
    const adapter = catalog.providers.find(
      (provider) =>
        provider.provider === model.engine &&
        provider.targets.includes('web') &&
        provider.capabilities.audio_bytes &&
        !provider.capabilities.online,
    );
    if (!adapter || !model.runtime_available || model.artifacts.length === 0) return [];
    return [
      {
        engine: model.engine,
        model_id: model.id,
        voice: null,
        session: {
          version: 2,
          provider: model.engine,
          runtime: adapter.runtime,
          model_id: model.id,
          model_revision: model.revision,
          voice: null,
          options: {},
        },
      },
    ];
  });
}
/** Piper's OPFS adapter names a model's pair using its catalog ID. */
export function browserArtifacts(model: TtsCatalogModel): TtsArtifact[] {
  return model.artifacts.map((artifact) => ({
    ...artifact,
    name:
      artifact.name === 'model.onnx'
        ? `${model.id}.onnx`
        : artifact.name === 'model.onnx.json'
          ? `${model.id}.onnx.json`
          : artifact.name,
  }));
}
