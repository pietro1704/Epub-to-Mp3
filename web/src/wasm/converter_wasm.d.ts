/* tslint:disable */
/* eslint-disable */

/**
 * Browser binding for Rust-owned segment ordering, provider policy and artifacts.
 */
export class ConversionSession {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Accept bounded MP3 encoded by the shared Rust codec.
     */
    accept_audio(audio: Uint8Array): boolean;
    cancel(): void;
    chapter_audio(): Uint8Array;
    constructor(chapters_json: string, preferences_json: string, language: string);
    next_segment(): string;
    provider_failed(): void;
}

/**
 * The browser provider supplies bounded PCM WAV; the shared Rust codec owns MP3.
 */
export function encode_wav_mp3(bytes: Uint8Array): Uint8Array;

export function health(): string;

/**
 * Parse an EPUB supplied by the browser and return its book structure as JSON.
 * Audio synthesis remains a separate capability until a browser-safe backend
 * is wired into the shared Rust pipeline.
 */
export function inspect_epub(bytes: Uint8Array): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_conversionsession_free: (a: number, b: number) => void;
    readonly conversionsession_accept_audio: (a: number, b: number, c: number, d: number) => void;
    readonly conversionsession_cancel: (a: number) => void;
    readonly conversionsession_chapter_audio: (a: number, b: number) => void;
    readonly conversionsession_new: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly conversionsession_next_segment: (a: number, b: number) => void;
    readonly conversionsession_provider_failed: (a: number, b: number) => void;
    readonly encode_wav_mp3: (a: number, b: number, c: number) => void;
    readonly health: (a: number) => void;
    readonly inspect_epub: (a: number, b: number, c: number) => void;
    readonly __wbindgen_add_to_stack_pointer: (a: number) => number;
    readonly __wbindgen_export: (a: number, b: number) => number;
    readonly __wbindgen_export2: (a: number, b: number, c: number) => void;
    readonly __wbindgen_export3: (a: number, b: number, c: number, d: number) => number;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
