import { act, fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import QuickQueueAdder from '../components/QuickQueueAdder';
import { renderWithProviders } from './testUtils';

describe('QuickQueueAdder terminal state', () => {
  it.each(['error', 'cancelled', 'idle'] as const)(
    'releases the active phase label after %s and still accepts another book', async (phase) => {
      const upload = vi.fn().mockResolvedValue({ uploadId: 'replacement', fileName: 'second.epub' });
      const enqueue = vi.fn().mockResolvedValue(undefined);
      const props = { template: { engine: 'piper', footnoteMode: 'inline' } as const, uploadFile: upload, enqueue };
      const view = renderWithProviders(<QuickQueueAdder {...props} phase="polling" />);
      expect(screen.getByText('Convertendo')).toBeInTheDocument();
      view.rerender(<QuickQueueAdder {...props} phase={phase} />);
      expect(screen.queryByText('Convertendo')).not.toBeInTheDocument();
      await act(async () => {
        fireEvent.change(screen.getByLabelText('Escolha EPUB/PDF adicionais'), {
          target: { files: [new File(['book'], 'second.epub', { type: 'application/epub+zip' })] },
        });
      });
      expect(enqueue).toHaveBeenCalledWith([expect.objectContaining({ uploadId: 'replacement' })]);
    },
  );
});
