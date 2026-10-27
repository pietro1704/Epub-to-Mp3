import { act, fireEvent, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import NativeReaderFallback from '../components/NativeReaderFallback';
import StreamingAudioPlayer from '../components/StreamingAudioPlayer';
import { conversionClient } from '../services/ConversionService';
import { browserNativeSpeech } from '../services/BrowserNativeSpeech';
import { renderWithProviders } from './testUtils';

vi.mock('../services/BrowserNativeSpeech', () => ({ browserNativeSpeech: vi.fn() }));
afterEach(() => vi.restoreAllMocks());

it('shares native voice, pause and completion with the player without completing an MP3 job', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({ language: 'pt-BR', voice: null });
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => undefined);
  let complete!: () => void;
  const speech = {
    speak: vi.fn((_text, _locale, _voice, onVoice) => {
      onVoice('Luciana (pt-BR)');
      return new Promise<void>(resolve => { complete = resolve; });
    }),
    pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(),
  };
  vi.mocked(browserNativeSpeech).mockReturnValue(speech as unknown as ReturnType<typeof browserNativeSpeech>);
  const view = renderWithProviders(<>
    <NativeReaderFallback jobId="native-job" chapterIndex={4} text="Current source text" />
    <StreamingAudioPlayer jobId="native-job" chapters={[{ index: 4, name: 'Source chapter', status: 'failed' }]} />
  </>);
  await waitFor(() => expect(screen.getByText('Ouvir com voz instalada do sistema')).toBeInTheDocument());
  fireEvent.click(screen.getByText('Ouvir com voz instalada do sistema'));
  expect(screen.getByText('Ouvindo com voz do sistema')).toBeInTheDocument();
  expect(screen.queryByText('Pronto para começar')).not.toBeInTheDocument();
  expect(screen.getAllByText('Luciana (pt-BR)').length).toBe(2);
  fireEvent.click(screen.getByText('Pausar'));
  expect(screen.getByText('Narração do sistema pausada')).toBeInTheDocument();
  fireEvent.click(screen.getByText('Continuar'));
  expect(screen.getByText('Ouvindo com voz do sistema')).toBeInTheDocument();
  await act(async () => { complete(); });
  expect(screen.getByText('Narração do sistema concluída')).toBeInTheDocument();
  expect(screen.getByText(/exportar MP3 exige Piper/)).toBeInTheDocument();
  expect(view.container.querySelector('audio')?.getAttribute('src')).toBeNull();
  view.unmount();
});

it('shows localized native failure and rejects a late completion after replacing the job', async () => {
  vi.spyOn(conversionClient, 'getNativePlaybackPolicy').mockResolvedValue({ language: 'en-US', voice: null });
  let rejectOld!: (error: Error) => void;
  const speech = {
    speak: vi.fn(() => new Promise<void>((_resolve, reject) => { rejectOld = reject; })),
    pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(),
  };
  vi.mocked(browserNativeSpeech).mockReturnValue(speech as unknown as ReturnType<typeof browserNativeSpeech>);
  const content = (jobId: string) => <>
    <NativeReaderFallback jobId={jobId} chapterIndex={0} text="Source text" />
    <StreamingAudioPlayer jobId={jobId} chapters={[{ index: 0, name: 'Chapter', status: 'failed' }]} />
  </>;
  const view = renderWithProviders(content('first'), { locale: 'en' });
  await waitFor(() => expect(screen.getByText('Listen with installed system voice')).toBeInTheDocument());
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  expect(screen.getByText('Preparing system voice')).toBeInTheDocument();
  view.rerender(content('second'));
  await act(async () => { rejectOld(new Error('Old private failure')); });
  expect(screen.queryByText('System narration failed')).not.toBeInTheDocument();
  expect(screen.queryByText('Old private failure')).not.toBeInTheDocument();
  fireEvent.click(screen.getByText('Listen with installed system voice'));
  await act(async () => { rejectOld(new Error('Current runtime failure')); });
  expect(screen.getByText('System narration failed')).toBeInTheDocument();
  expect(screen.getByRole('status')).toHaveTextContent('Check offline system voices');
  expect(screen.getByText('Listen with installed system voice')).toBeEnabled();
  view.unmount();
});
