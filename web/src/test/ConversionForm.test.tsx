import { act, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('../services/TtsCatalog', () => ({
  loadTtsCatalog: vi.fn(async () => ({ version: 2, providers: [], models: [] })),
  browserSelections: vi.fn(() => []),
}));
import ConversionForm from '../components/ConversionForm';
import type { UploadResponse } from '../services/ConversionService';
import { renderWithProviders } from './testUtils';

describe('ConversionForm', () => {
  beforeEach(() => localStorage.clear());
  it('routes a Tauri Open Books menu event through actual File upload without HTTP path IDs', async () => {
    const listeners = new Map<string, (event: { payload: unknown }) => void>();
    const native = vi.fn();
    Object.defineProperty(window, '__TAURI__', {
      configurable: true,
      value: {
        core: { invoke: native },
        event: {
          listen: vi.fn(async (name: string, handler: (event: { payload: unknown }) => void) => {
            listeners.set(name, handler);
            return () => listeners.delete(name);
          }),
        },
      },
    });
    const network = vi.spyOn(globalThis, 'fetch');
    try {
      const user = userEvent.setup();
      const upload = vi
        .fn()
        .mockResolvedValue({
          uploadId: 'browser-upload',
          fileName: 'local.epub',
          bookTitle: 'Local book',
          bookAuthor: 'Author',
        });
      const submit = vi.fn();
      renderWithProviders(
        <ConversionForm isSubmitting={false} onSubmit={submit} onUploadFile={upload} />,
      );
      await waitFor(() => expect(listeners.has('tauri-open-books')).toBe(true));
      const input = screen.getByLabelText(/arquivo do livro/i);
      const picker = vi.spyOn(input, 'click').mockImplementation(() => undefined);
      await act(async () => {
        listeners.get('tauri-open-books')?.({ payload: null });
      });
      expect(picker).toHaveBeenCalledTimes(1);
      picker.mockRestore();
      const file = new File(['EPUB fixture'], 'local.epub', { type: 'application/epub+zip' });
      await user.upload(input, file);
      await waitFor(() => expect(upload).toHaveBeenCalledWith(file));
      await waitFor(() => expect(screen.getByText('Local book')).toBeInTheDocument());
      await user.click(screen.getByRole('button', { name: /converter agora/i }));
      await waitFor(() =>
        expect(submit).toHaveBeenCalledWith(
          expect.objectContaining({
            uploadId: 'browser-upload',
            bookTitle: 'Local book',
            bookAuthor: 'Author',
          }),
          expect.anything(),
        ),
      );
      expect(submit.mock.calls[0][0].file).toBeNull();
      expect(upload).toHaveBeenCalledTimes(1);
      expect(network).not.toHaveBeenCalled();
      expect(native).not.toHaveBeenCalled();
    } finally {
      network.mockRestore();
      delete window.__TAURI__;
    }
  });

  it('shows error message when no file is selected', async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn();
    const handleUpload = vi.fn().mockResolvedValue({ uploadId: 'test', fileName: 'sample.epub' });
    renderWithProviders(
      <ConversionForm isSubmitting={false} onSubmit={handleSubmit} onUploadFile={handleUpload} />,
    );

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent(
        'Selecione um arquivo EPUB ou PDF antes de enviar.',
      );
    });
    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it('submits selected values using automatic upload', async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    const handleUpload = vi.fn().mockResolvedValue({ uploadId: 'test', fileName: 'sample.epub' });
    renderWithProviders(
      <ConversionForm isSubmitting={false} onSubmit={handleSubmit} onUploadFile={handleUpload} />,
    );

    const file = new File(['content'], 'sample.epub', {
      type: 'application/epub+zip',
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /converter agora/i })).toBeEnabled(),
    );
    await user.selectOptions(screen.getByLabelText(/como quer/i), 'piper');
    await user.selectOptions(screen.getByLabelText(/nome da voz/i), 'pt_BR-faber-medium.onnx');
    await user.type(screen.getByLabelText(/quais capítulos você quer/i), '1,2');
    await user.selectOptions(screen.getByLabelText(/idioma do áudio/i), 'en');
    await user.click(screen.getByLabelText(/ler depois do capítulo/i));

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => {
      expect(handleSubmit).toHaveBeenCalledTimes(1);
      expect(handleSubmit.mock.calls[0][0]).toMatchObject({
        file: null,
        fileName: 'sample.epub',
        uploadId: 'test',
        engine: 'piper',
        voice: 'pt_BR-faber-medium.onnx',
        chapters: '1,2',
        footnoteMode: 'chapter_end',
        language: 'en',
      });
    });
  }, 10000);

  it('shows status while auto-detecting cover', async () => {
    const user = userEvent.setup();
    let resolveUpload: ((value: UploadResponse) => void) | undefined;
    const handleSubmit = vi.fn();
    const handleUpload = vi.fn().mockImplementation(
      () =>
        new Promise<UploadResponse>((resolve) => {
          resolveUpload = resolve;
        }),
    );
    renderWithProviders(
      <ConversionForm isSubmitting={false} onSubmit={handleSubmit} onUploadFile={handleUpload} />,
    );

    const file = new File(['content'], 'sample.epub', {
      type: 'application/epub+zip',
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    expect(screen.getByText(/detectar capa/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /converter agora/i })).toBeDisabled();

    resolveUpload?.({ uploadId: 'auto-id', fileName: 'sample.epub' });
    await waitFor(() => expect(screen.getByText(/metadados detectados/i)).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /converter agora/i })).toBeEnabled();
  });

  it('defaults to installed-offline Faber policy without unsupported character voices', async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    const handleUpload = vi.fn().mockResolvedValue({ uploadId: 'voices', fileName: 'sample.epub' });
    renderWithProviders(
      <ConversionForm isSubmitting={false} onSubmit={handleSubmit} onUploadFile={handleUpload} />,
    );

    const file = new File(['content'], 'sample.epub', {
      type: 'application/epub+zip',
    });
    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /converter agora/i })).toBeEnabled(),
    );

    // Fresh preferences must be offline and avoid unsupported character synthesis.
    const toggle = screen.getByLabelText(/vozes diferentes para narrador e personagens/i);
    expect(toggle).not.toBeChecked();
    expect(screen.queryByLabelText(/voz do narrador/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/voz dos personagens/i)).not.toBeInTheDocument();
    expect(screen.getByRole('combobox', { name: 'Voz principal' })).toHaveValue(
      'pt_BR-faber-medium',
    );
    expect(screen.getByRole('combobox', { name: 'Voz secundária' })).toHaveValue('system');

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => expect(handleSubmit).toHaveBeenCalledTimes(1));
    expect(handleSubmit.mock.calls[0][0]).toMatchObject({
      engine: 'piper',
      enableCharacterVoices: false,
      formattingCues: false,
      tts_preferences: {
        primary: { engine: 'piper', model_id: 'pt_BR-faber-medium', voice: null },
        secondary: { engine: 'system', model_id: null, voice: null },
        policy_version: 2,
        allow_online_fallback: false,
      },
    });
  }, 10000);
});
