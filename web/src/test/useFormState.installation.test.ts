import { act, renderHook } from '@testing-library/react';
import { beforeEach, expect, it, vi } from 'vitest';
import { useFormState } from '../components/useFormState';
import { installBrowserModel } from '../services/BrowserConversionClient';
import { createProvidersWrapper } from './testUtils';
vi.mock('../services/BrowserConversionClient', () => ({
  browserVoiceId: 'pt_BR-faber-medium',
  installedBrowserVoices: vi.fn(async () => []),
  installBrowserModel: vi.fn(async () => undefined),
}));
beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
});
it('installs the effective manual model without changing the global primary', async () => {
  const { result } = renderHook(() => useFormState(), { wrapper: createProvidersWrapper('en') });
  await act(async () => {
    result.current.setCatalogSelection({
      engine: 'piper',
      model_id: 'pt_BR-edresson-low',
      voice: null,
    });
    result.current.setUsePreferences(false);
  });
  await act(async () => {
    await result.current.installModel();
  });
  expect(installBrowserModel).toHaveBeenCalledWith('pt_BR-edresson-low');
  expect(result.current.preferences.primary.model_id).toBe('pt_BR-faber-medium');
  await act(async () => {
    result.current.setUsePreferences(true);
  });
  await act(async () => {
    await result.current.installModel();
  });
  expect(installBrowserModel).toHaveBeenLastCalledWith('pt_BR-faber-medium');
});
it('ignores an installation failure after switching to another model', async () => {
  let reject!: (error: Error) => void;
  vi.mocked(installBrowserModel).mockImplementationOnce(
    () =>
      new Promise((_, no) => {
        reject = no;
      }),
  );
  const { result } = renderHook(() => useFormState(), { wrapper: createProvidersWrapper('en') });
  let pending!: Promise<void>;
  act(() => {
    pending = result.current.installModel();
  });
  await act(async () => {
    result.current.setCatalogSelection({
      engine: 'piper',
      model_id: 'pt_BR-edresson-low',
      voice: null,
    });
    result.current.setUsePreferences(false);
  });
  await act(async () => {
    reject(new Error('Old model failed'));
    await pending;
  });
  expect(result.current.modelStatus).toBe('idle');
  expect(result.current.modelError).toBe('');
});
