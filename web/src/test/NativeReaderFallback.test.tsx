import { act, fireEvent, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { renderWithProviders } from './testUtils';
import NativeReaderFallback from '../components/NativeReaderFallback';
import { conversionClient } from '../services/ConversionService';
import { browserNativeSpeech } from '../services/BrowserNativeSpeech';
import { nativeSpeechFixture } from './nativeSpeechFixture';

vi.mock('../services/BrowserNativeSpeech', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/BrowserNativeSpeech')>()),
  browserNativeSpeech: vi.fn(),
}));
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

it('connects captured policy to speech and retires controls on chapter and primary playback changes', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(
    <NativeReaderFallback jobId="book" chapterIndex={0} text="Chapter one" />,
    { locale: 'en' },
  );
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  expect(fixture.utterances[0].text).toBe('Chapter one');
  expect(fixture.utterances[0].lang).toBe('pt-BR');
  expect(fixture.utterances[0].voice?.voiceURI).toBe('local-luciana');
  act(() => fixture.start());
  fireEvent.click(screen.getByText('Pause'));
  expect(fixture.synthesis.pause).toHaveBeenCalledOnce();
  fireEvent.click(screen.getByText('Resume'));
  expect(fixture.synthesis.resume).toHaveBeenCalledOnce();
  const cancellations = fixture.synthesis.cancel.mock.calls.length;
  view.rerender(<NativeReaderFallback jobId="book" chapterIndex={1} text="Chapter two" />);
  expect(fixture.synthesis.cancel.mock.calls.length).toBeGreaterThan(cancellations);
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  expect(fixture.utterances.at(-1)?.text).toBe('Chapter two');
  await act(async () => {
    document.dispatchEvent(new Event('play'));
  });
  expect(screen.getByText('Listen with installed system voice')).toBeEnabled();
  view.unmount();
});

it('rejects late speech events and Piper retry failures from the previous chapter', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  let failRetry!: (error: Error) => void;
  vi.spyOn(conversionClient, 'resume').mockImplementation(
    () =>
      new Promise((_resolve, reject) => {
        failRetry = reject;
      }),
  );
  const view = renderWithProviders(
    <NativeReaderFallback jobId="book" chapterIndex={0} text="First" />,
    { locale: 'en' },
  );
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  fireEvent.click(screen.getByText('Retry Piper conversion'));
  fixture.synthesis.getVoices.mockReturnValue([
    { ...fixture.voice, name: 'Current voice', voiceURI: 'current' },
  ]);
  view.rerender(<NativeReaderFallback jobId="book" chapterIndex={1} text="Second" />);
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  await act(async () => {
    fixture.start(0);
    fixture.fail('Stale private failure', 0);
    fixture.end(0);
    failRetry(new Error('Stale private retry'));
  });
  expect(screen.getByRole('status')).toHaveTextContent('Current voice (pt-BR)');
  expect(screen.getByText('Listen with installed system voice')).toBeDisabled();
  view.unmount();
});

it('localizes unavailable speech and current Piper retry failures', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  vi.mocked(browserNativeSpeech).mockReturnValue(undefined);
  vi.spyOn(conversionClient, 'resume').mockRejectedValue(new Error('Private runtime detail'));
  const view = renderWithProviders(
    <NativeReaderFallback jobId="book" chapterIndex={0} text="Source" />,
    { locale: 'en' },
  );
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  expect(screen.getByRole('status')).toHaveTextContent(
    'System speech is unavailable in this browser.',
  );
  fireEvent.click(screen.getByText('Retry Piper conversion'));
  await waitFor(() =>
    expect(screen.getByRole('status')).toHaveTextContent(
      'Could not resume Piper conversion. Try again.',
    ),
  );
  expect(screen.queryByText('Private runtime detail')).not.toBeInTheDocument();
  view.unmount();
});

it('retains captured policy through a transient refresh failure while speech is active', async () => {
  vi.useFakeTimers();
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy')
    .mockResolvedValueOnce({ language: 'pt-BR', voice: null })
    .mockRejectedValue(new Error('Transient private failure'));
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(
    <NativeReaderFallback jobId="book" chapterIndex={0} text="Source" />,
    { locale: 'en' },
  );
  await act(async () => undefined);
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  await act(async () => {
    await vi.advanceTimersByTimeAsync(1000);
  });
  expect(screen.getByText('Pause')).toBeEnabled();
  expect(screen.getByRole('status')).toHaveTextContent('Luciana (pt-BR)');
  view.unmount();
});

it('waits for the replacement job policy before exposing its voice selection', async () => {
  let resolvePolicy!: (value: { language: string; voice: string | null }) => void;
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockImplementation((jobId) =>
    jobId === 'first'
      ? Promise.resolve({ language: 'pt-BR', voice: null })
      : new Promise((resolve) => {
          resolvePolicy = resolve;
        }),
  );
  const fixture = nativeSpeechFixture();
  fixture.synthesis.getVoices.mockReturnValue([
    fixture.voice,
    { ...fixture.voice, name: 'Selected voice', voiceURI: 'selected' },
  ]);
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(
    <NativeReaderFallback jobId="first" chapterIndex={0} text="First" />,
    { locale: 'en' },
  );
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  view.rerender(<NativeReaderFallback jobId="second" chapterIndex={0} text="Second" />);
  expect(screen.queryByText('Listen with installed system voice')).not.toBeInTheDocument();
  await act(async () => {
    resolvePolicy({ language: 'pt-BR', voice: 'selected' });
  });
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  expect(fixture.utterances.at(-1)?.voice?.voiceURI).toBe('selected');
  view.unmount();
});
