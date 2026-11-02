import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import NativeReaderFallback from '../components/NativeReaderFallback';
import StreamingAudioPlayer from '../components/StreamingAudioPlayer';
import { conversionClient } from '../services/ConversionService';
import { browserNativeSpeech } from '../services/BrowserNativeSpeech';
import { renderWithProviders } from './testUtils';
import { nativeSpeechFixture } from './nativeSpeechFixture';

vi.mock('../services/BrowserNativeSpeech', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/BrowserNativeSpeech')>()),
  browserNativeSpeech: vi.fn(),
}));
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

const content = (jobId: string) => (
  <>
    <NativeReaderFallback jobId={jobId} chapterIndex={4} text="Current source text" />
    <StreamingAudioPlayer
      jobId={jobId}
      chapters={[{ index: 4, name: 'Source chapter', status: 'failed' }]}
    />
  </>
);

it('shares actual speech startup, pause and completion without completing an MP3 job', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  const resume = vi.spyOn(conversionClient, 'resume');
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => undefined);
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(content('native-job'), { locale: 'pt' });
  await waitFor(() => expect(screen.getByText('Ouvir com voz instalada do sistema')).toBeEnabled());
  fireEvent.click(screen.getByText('Ouvir com voz instalada do sistema'));
  expect(screen.getByText('Preparando voz do sistema')).toBeInTheDocument();
  expect(screen.getByText('Pausar')).toBeDisabled();
  act(() => fixture.start());
  expect(screen.getByText('Ouvindo com voz do sistema')).toBeInTheDocument();
  expect(screen.queryByText('Pronto para começar')).not.toBeInTheDocument();
  expect(screen.getAllByText('Luciana (pt-BR)')).toHaveLength(2);
  fireEvent.click(screen.getByText('Pausar'));
  expect(screen.getByText('Narração do sistema pausada')).toBeInTheDocument();
  expect(fixture.synthesis.pause).toHaveBeenCalledOnce();
  act(() => fixture.start());
  expect(screen.getByText('Narração do sistema pausada')).toBeInTheDocument();
  fireEvent.click(screen.getByText('Continuar'));
  expect(screen.getByText('Ouvindo com voz do sistema')).toBeInTheDocument();
  await act(async () => {
    fixture.end();
  });
  expect(screen.getByText('Narração do sistema concluída')).toBeInTheDocument();
  act(() => {
    fixture.speech.pause();
    fixture.speech.resume();
  });
  expect(screen.getByText('Narração do sistema concluída')).toBeInTheDocument();
  expect(screen.getByText(/exportar MP3 exige Piper/)).toBeInTheDocument();
  expect(view.container.querySelector('audio')?.getAttribute('src')).toBeNull();
  expect(resume).not.toHaveBeenCalled();
  view.unmount();
});

it('rejects old speech events after replacing a job and localizes current failures', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => undefined);
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(content('first'), { locale: 'en' });
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  view.rerender(content('second'));
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeEnabled());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  await act(async () => {
    fixture.fail('Old private failure', 0);
    fixture.end(0);
  });
  expect(screen.getByText('Listening with system voice')).toBeInTheDocument();
  expect(screen.queryByText('Old private failure')).not.toBeInTheDocument();
  await act(async () => {
    fixture.fail('Current private failure');
  });
  expect(screen.getByText('System narration failed')).toBeInTheDocument();
  expect(screen.getByRole('status')).toHaveTextContent('Check offline system voices');
  expect(screen.queryByText('Current private failure')).not.toBeInTheDocument();
  expect(screen.getByText('Listen with installed system voice')).toBeEnabled();
  view.unmount();
});

it('old component teardown cannot cancel or clear a newer narration owner', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => undefined);
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const first = renderWithProviders(content('first'), { locale: 'en' });
  await waitFor(() =>
    expect(within(first.container).getByText('Listen with installed system voice')).toBeEnabled(),
  );
  fireEvent.click(within(first.container).getByText('Listen with installed system voice'));
  act(() => fixture.start());
  const second = renderWithProviders(content('second'), { locale: 'en' });
  await waitFor(() =>
    expect(within(second.container).getByText('Listen with installed system voice')).toBeEnabled(),
  );
  fireEvent.click(within(second.container).getByText('Listen with installed system voice'));
  act(() => fixture.start());
  const cancellations = fixture.synthesis.cancel.mock.calls.length;
  first.unmount();
  expect(fixture.synthesis.cancel).toHaveBeenCalledTimes(cancellations);
  expect(within(second.container).getByText('Listening with system voice')).toBeInTheDocument();
  second.unmount();
});

it('publishes a bounded speech timeout as a failure and ignores its late start and end events', async () => {
  vi.useFakeTimers();
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({
    language: 'pt-BR',
    voice: null,
  });
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => undefined);
  const fixture = nativeSpeechFixture();
  vi.mocked(browserNativeSpeech).mockReturnValue(fixture.speech);
  const view = renderWithProviders(content('timeout'), { locale: 'en' });
  await act(async () => undefined);
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  act(() => fixture.start());
  const cancellations = fixture.synthesis.cancel.mock.calls.length;
  await act(async () => {
    await vi.advanceTimersByTimeAsync(120_000);
  });
  expect(fixture.synthesis.cancel.mock.calls.length).toBeGreaterThan(cancellations);
  expect(screen.getByText('System narration failed')).toBeInTheDocument();
  await act(async () => {
    fixture.start();
    fixture.end();
  });
  expect(screen.getByText('System narration failed')).toBeInTheDocument();
  view.unmount();
});
