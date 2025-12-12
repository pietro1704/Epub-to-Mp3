import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import ConversionForm from '../components/ConversionForm';
import { renderWithProviders } from './testUtils';

describe('ConversionForm', () => {
  it('exibe mensagem de erro quando nenhum arquivo é selecionado', async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn();
    renderWithProviders(<ConversionForm isSubmitting={false} onSubmit={handleSubmit} />);

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent('Selecione um arquivo');
    });
    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it('envia os valores selecionados', async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    renderWithProviders(<ConversionForm isSubmitting={false} onSubmit={handleSubmit} />);

    const file = new File(['conteúdo'], 'amostra.epub', { type: 'application/epub+zip' });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await user.selectOptions(screen.getByLabelText(/como quer/i), 'coqui');
    await user.selectOptions(screen.getByLabelText(/nome da voz/i), 'pt-br-fernanda');
    await user.type(screen.getByLabelText(/quais capítulos/i), '1,2');
    await user.selectOptions(screen.getByLabelText(/idioma do áudio/i), 'en');
    await user.click(screen.getByLabelText(/ler depois do capítulo/i));

    await user.click(screen.getByRole('button', { name: /converter agora/i }));

    await waitFor(() => {
      expect(handleSubmit).toHaveBeenCalledTimes(1);
      expect(handleSubmit.mock.calls[0][0]).toMatchObject({
        file,
        engine: 'coqui',
        voice: 'pt-br-fernanda',
        chapters: '1,2',
        footnoteMode: 'chapter_end',
        language: 'en',
      });
    });
  });
});
