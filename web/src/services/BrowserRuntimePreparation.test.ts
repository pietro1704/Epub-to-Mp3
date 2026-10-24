import { beforeEach, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({
  default: vi.fn(async () => undefined),
  ConversionSession: vi.fn(),
}));
import { ConversionSession } from '../wasm/converter_wasm';
import { platformRuntime } from './BrowserConversionRuntime';
import { BrowserTtsPreparationError } from './BrowserTtsFailure';
import { faber } from './TtsPreferences';
const preferences = {
  policy_version: 2,
  primary: faber,
  secondary: null,
  allow_online_fallback: false,
};
beforeEach(() => vi.clearAllMocks());
it('classifies the Rust preparation rejection so listening recovery stays available', async () => {
  vi.mocked(ConversionSession).mockImplementationOnce(function () {
    throw 'Language is unavailable in this runtime';
  });
  await expect(
    platformRuntime.create(
      [{ index: 0, name: 'Chapter', text: 'English source', charCount: 14 }],
      preferences,
      'en-US',
    ),
  ).rejects.toBeInstanceOf(BrowserTtsPreparationError);
});
it('preserves a saved-state rejection and frees the prepared Rust session', async () => {
  const free = vi.fn();
  const failure = new Error('Corrupt saved policy');
  vi.mocked(ConversionSession).mockImplementationOnce(function () {
    return {
      free,
      restore_policy_state_json: () => {
        throw failure;
      },
    } as ConversionSession;
  });
  await expect(
    platformRuntime.create(
      [{ index: 0, name: 'Chapter', text: 'Source', charCount: 6 }],
      preferences,
      'pt-BR',
      'corrupt',
    ),
  ).rejects.toBe(failure);
  expect(free).toHaveBeenCalledOnce();
});
