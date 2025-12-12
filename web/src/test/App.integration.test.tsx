import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import App from '../App';
import type { ConversionClient } from '../services/ConversionService';
import type { JobSnapshot } from '../types/conversion';
import { renderWithProviders } from './testUtils';

describe('App integration', () => {
  it('executa o fluxo completo de conversão com cliente customizado', async () => {
    const user = userEvent.setup();
    const submit = vi.fn().mockResolvedValue({ jobId: 'job-777' });
    const poll = vi.fn().mockImplementation(async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
      options?.onSnapshot?.({
        jobId: 'job-777',
        state: 'running',
        events: ['Arquivo carregado', 'Sintetizando capítulo 1'],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 2,
        chaptersCompleted: 1,
        currentChapter: 'Capítulo 1',
        progressPercent: 45,
      });
      return {
        jobId: 'job-777',
        state: 'finished',
        outputs: [
          { name: 'Capítulo 1.mp3', url: 'https://cdn.example/audio-1.mp3' },
          { name: 'Capítulo 2.mp3', url: 'https://cdn.example/audio-2.mp3' },
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 2,
        chaptersCompleted: 2,
        currentChapter: 'Capítulo 2',
        progressPercent: 100,
      } satisfies JobSnapshot;
    });

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    renderWithProviders(<App client={client} />);

    const file = new File(['ebook'], 'historia.pdf', { type: 'application/pdf' });
    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => expect(screen.getByText(/sintetizando capítulo 1/i)).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText(/tudo pronto/i)).toBeInTheDocument());
    expect(screen.getByText(/tempo estimado/i)).toBeInTheDocument();
    expect(screen.getByText(/resumo da execução/i)).toBeInTheDocument();
    expect(screen.getByText(/português \(brasil\)/i)).toBeInTheDocument();

    expect(submit).toHaveBeenCalledWith({
      file,
      engine: 'edge',
      voice: 'pt-BR-ThalitaNeural',
      chapters: undefined,
      footnoteMode: 'inline',
      language: undefined,
    });
    expect(poll).toHaveBeenCalledWith('job-777', expect.any(Object));

    expect(screen.getByText(/Capítulo 1.mp3/)).toBeInTheDocument();
    expect(screen.getByText(/Capítulo 2.mp3/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /começar uma nova conversão/i }));

    await waitFor(() => expect(screen.getByText(/pronto para começar/i)).toBeInTheDocument());
    expect(screen.queryByText(/Capítulo 1.mp3/)).not.toBeInTheDocument();
  });
});
