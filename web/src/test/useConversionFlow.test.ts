import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useConversionFlow } from '../hooks/useConversionFlow';
import type { ConversionClient } from '../services/ConversionService';
import type { ConversionFormValues, JobSnapshot } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';
import { conversionCache } from '../services/ConversionCache';

describe('useConversionFlow lifecycle', () => {
  beforeEach(() => {
    // Isolate localStorage from real data
    localStorage.clear();
  });

  const file = new File(['data'], 'book.epub', {
    type: 'application/epub+zip',
  });

  const request: ConversionFormValues = {
    file,
    engine: 'edge',
    footnoteMode: 'inline',
  };

  it('keeps the failed job recipe and clears it for a new browser-only source', async () => {
    const client: ConversionClient = {
      mode: 'embedded',
      submit: vi
        .fn()
        .mockResolvedValueOnce({ jobId: 'local-failed' })
        .mockResolvedValueOnce({ jobId: 'browser-next' }),
      fetch: vi.fn(),
      poll: vi
        .fn()
        .mockResolvedValueOnce({
          jobId: 'local-failed',
          state: 'failed',
          error: 'Model missing',
        })
        .mockResolvedValueOnce({ jobId: 'browser-next', state: 'finished' }),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    await act(async () => {
      await result.current.submit({
        ...request,
        localPath: '/books/local.epub',
        engine: 'piper',
        tts_preferences: {
          primary: { engine: 'piper', model_id: 'pt_BR-faber-medium', voice: null },
          secondary: null,
          allow_online_fallback: false,
        },
      });
    });
    expect(result.current.state.phase).toBe('error');
    expect(result.current.state.jobId).toBe('local-failed');
    expect(result.current.state.cliCommand).toContain('--tts-preferences-json');
    expect(result.current.state.cliShell).toBe('Bash/Zsh');
    expect(result.current.state.cliCommand).not.toContain('python');
    await act(async () => {
      await result.current.submit(request);
    });
    expect(result.current.state.jobId).toBe('browser-next');
    expect(result.current.state.cliCommand).toBeUndefined();
    expect(result.current.state.cliShell).toBeUndefined();
  });

  it('completes conversion successfully and records events', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: '123' });
    const poll = vi
      .fn()
      .mockImplementation(
        async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
          options?.onSnapshot?.({
            jobId: '123',
            state: 'running',
            events: ['Extracting chapters', 'Generating audio'],
          });
          return {
            jobId: '123',
            state: 'finished',
            outputs: [{ name: 'capitulo-1.mp3', url: '/audio/1.mp3' }],
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('pt'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(submit).toHaveBeenCalledWith(request);
    expect(poll).toHaveBeenCalledWith('123', expect.any(Object));
    expect(result.current.state.phase).toBe('success');
    expect(result.current.state.downloads).toHaveLength(1);
    expect(result.current.state.etaSeconds).toBe(0);
    expect(result.current.state.summary?.progressPercent).toBe(100);
    const messages = result.current.state.log.map((entry) => entry.message);
    expect(messages).toEqual([
      expect.stringMatching(/Enviando arquivo/i),
      expect.stringContaining('Pedido 123'),
      'Extracting chapters',
      'Generating audio',
      expect.stringContaining('Conversão finalizada'),
    ]);
  });

  it('propagates error when conversion fails', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: '321' });
    const poll = vi.fn().mockResolvedValue({
      jobId: '321',
      state: 'failed',
      error: 'Falha na síntese',
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('pt'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe('error');
    expect(result.current.state.error).toBe('Falha na síntese');
    expect(result.current.state.etaSeconds).toBe(0);
    const lastMessage = result.current.state.log.at(-1)?.message ?? '';
    expect(lastMessage).toContain('Falha');
  });

  it('removes file from payload when a prior upload already exists', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: '555' });
    const poll = vi.fn().mockResolvedValue({
      jobId: '555',
      state: 'finished',
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('pt'),
    });

    const file = new File(['data'], 'book.epub', {
      type: 'application/epub+zip',
    });
    await act(async () => {
      await result.current.submit({
        file,
        fileName: 'book.epub',
        uploadId: 'upload-xyz',
        engine: 'edge',
        footnoteMode: 'inline',
      });
    });

    expect(submit).toHaveBeenCalledWith(
      expect.objectContaining({
        file: null,
        uploadId: 'upload-xyz',
        fileName: 'book.epub',
      }),
    );

    const firstMessage = result.current.state.log[0]?.message ?? '';
    expect(firstMessage).toContain('arquivo já enviado');
  });

  it('reset() returns state to idle and clears log', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: '777' });
    const poll = vi.fn().mockResolvedValue({
      jobId: '777',
      state: 'finished',
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('pt'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe('success');
    expect(result.current.state.log.length).toBeGreaterThan(0);

    act(() => {
      result.current.reset();
    });

    expect(result.current.state.phase).toBe('idle');
    expect(result.current.state.log).toHaveLength(0);
    expect(result.current.state.error).toBeUndefined();
  });

  it('dismissSavedBatch clears state and localStorage', () => {
    conversionCache.savePendingBatch([
      { file: null, uploadId: 'u1', engine: 'edge', footnoteMode: 'inline' },
    ]);

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    // savedBatch should be populated from localStorage
    expect(result.current.savedBatch).not.toBeNull();

    act(() => {
      result.current.dismissSavedBatch();
    });

    expect(result.current.savedBatch).toBeNull();
    expect(conversionCache.loadPendingBatch()).toBeNull();
  });

  it('resumeBatch skips items with no file and no uploadId', async () => {
    const submitMock = vi.fn().mockResolvedValue({ jobId: 'resume1' });
    const poll = vi.fn().mockResolvedValue({
      jobId: 'resume1',
      state: 'finished',
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit: submitMock,
      fetch: vi.fn(),
      poll,
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    const lostItem: ConversionFormValues = {
      file: null, // file lost during serialisation
      engine: 'edge',
      footnoteMode: 'inline',
    };
    const validItem: ConversionFormValues = {
      file: null,
      uploadId: 'existing-upload',
      fileName: 'book2.epub',
      engine: 'edge',
      footnoteMode: 'inline',
    };

    await act(async () => {
      await result.current.resumeBatch([lostItem, validItem]);
    });

    // lostItem is skipped; submitMock should be called with validItem
    expect(submitMock).toHaveBeenCalledWith(
      expect.objectContaining({ uploadId: 'existing-upload' }),
    );
    expect(result.current.savedBatch).toBeNull();
  });

  it('resumeBatch does nothing when all items have no file and no uploadId', async () => {
    const submitMock = vi.fn();
    const client: ConversionClient = {
      submit: submitMock,
      fetch: vi.fn(),
      poll: vi.fn(),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    const lostItem: ConversionFormValues = {
      file: null,
      engine: 'edge',
      footnoteMode: 'inline',
    };

    await act(async () => {
      await result.current.resumeBatch([lostItem]);
    });

    expect(submitMock).not.toHaveBeenCalled();
    expect(result.current.savedBatch).toBeNull();
  });
  it('keeps reset authoritative when an earlier submit resolves late', async () => {
    let resolveSubmit!: (result: { jobId: string }) => void;
    const poll = vi.fn().mockResolvedValue({ jobId: 'late-job', state: 'finished' });
    const client: ConversionClient = {
      mode: 'embedded',
      submit: vi.fn(
        () =>
          new Promise((resolve) => {
            resolveSubmit = resolve;
          }),
      ),
      fetch: vi.fn(),
      poll,
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    let submission!: Promise<void>;
    act(() => {
      submission = result.current.submit(request);
    });
    await waitFor(() => expect(client.submit).toHaveBeenCalledOnce());
    act(() => {
      result.current.reset();
    });
    expect(result.current.state.phase).toBe('idle');
    await act(async () => {
      resolveSubmit({ jobId: 'late-job' });
      await submission;
    });
    expect(result.current.state.phase).toBe('idle');
    expect(result.current.state.jobId).toBeUndefined();
    expect(poll).not.toHaveBeenCalled();
    expect(conversionCache.load('late-job')).toBeNull();
  });
});
