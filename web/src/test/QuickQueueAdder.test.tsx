import { act, fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import QuickQueueAdder from '../components/QuickQueueAdder';
import { renderWithProviders } from './testUtils';

const template = { engine: 'piper', footnoteMode: 'inline' } as const;
const replacement = () => new File(['book'], 'second.epub', { type: 'application/epub+zip' });

describe('QuickQueueAdder conversion phase', () => {
  it.each([
    ['idle', 'Pronto para começar'],
    ['submitting', 'Convertendo'],
    ['polling', 'Convertendo'],
    ['success', 'Pronto para próxima fila'],
    ['error', 'Ops, algo deu errado'],
    ['cancelling', 'Cancelando…'],
    ['cancelled', 'Cancelado'],
  ] as const)('shows the current %s phase', (phase, label) => {
    renderWithProviders(
      <QuickQueueAdder template={template} phase={phase} uploadFile={vi.fn()} enqueue={vi.fn()} />,
      { locale: 'pt' },
    );
    expect(screen.getByText(label)).toBeInTheDocument();
    if (phase !== 'polling' && phase !== 'submitting') {
      expect(screen.queryByText('Convertendo')).not.toBeInTheDocument();
    }
  });

  it.each(['error', 'cancelled', 'idle'] as const)(
    'releases the active label after %s and accepts a distinct replacement book',
    async (phase) => {
      const upload = vi
        .fn()
        .mockResolvedValue({ uploadId: 'replacement', fileName: 'second.epub' });
      const enqueue = vi.fn().mockResolvedValue(undefined);
      const props = { template, uploadFile: upload, enqueue };
      const view = renderWithProviders(<QuickQueueAdder {...props} phase="polling" />, {
        locale: 'pt',
      });
      expect(screen.getByText('Convertendo')).toBeInTheDocument();
      view.rerender(<QuickQueueAdder {...props} phase={phase} />);
      expect(screen.queryByText('Convertendo')).not.toBeInTheDocument();
      const file = replacement();
      await act(async () => {
        fireEvent.change(screen.getByLabelText('Escolha EPUB/PDF adicionais'), {
          target: { files: [file] },
        });
      });
      expect(upload).toHaveBeenCalledExactlyOnceWith(file);
      expect(enqueue).toHaveBeenCalledExactlyOnceWith([
        expect.objectContaining({ ...template, uploadId: 'replacement', fileName: 'second.epub' }),
      ]);
    },
  );

  it('keeps terminal conversion state during upload failure and permits retry', async () => {
    const upload = vi
      .fn()
      .mockRejectedValueOnce(new Error('Upload failed'))
      .mockResolvedValueOnce({ uploadId: 'replacement', fileName: 'second.epub' });
    const enqueue = vi.fn().mockResolvedValue(undefined);
    renderWithProviders(
      <QuickQueueAdder
        template={template}
        phase="cancelled"
        uploadFile={upload}
        enqueue={enqueue}
      />,
      { locale: 'en' },
    );
    const input = screen.getByLabelText('Select additional EPUB/PDF files');
    await act(async () => {
      fireEvent.change(input, { target: { files: [replacement()] } });
    });
    expect(screen.getByText('Upload failed')).toBeInTheDocument();
    expect(enqueue).not.toHaveBeenCalled();
    expect(input).toBeEnabled();
    expect(screen.getByText('Cancelled')).toBeInTheDocument();
    await act(async () => {
      fireEvent.change(input, { target: { files: [replacement()] } });
    });
    expect(enqueue).toHaveBeenCalledOnce();
    expect(screen.queryByText('Upload failed')).not.toBeInTheDocument();
    expect(screen.getByText('Cancelled')).toBeInTheDocument();
  });
});
