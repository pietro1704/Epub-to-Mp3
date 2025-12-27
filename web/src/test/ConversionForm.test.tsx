import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import ConversionForm from "../components/ConversionForm";
import type { UploadResponse } from "../services/ConversionService";
import { renderWithProviders } from "./testUtils";

describe("ConversionForm", () => {
  it("exibe mensagem de erro quando nenhum arquivo é selecionado", async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn();
    const handleUpload = vi
      .fn()
      .mockResolvedValue({ uploadId: "test", fileName: "amostra.epub" });
    renderWithProviders(
      <ConversionForm
        isSubmitting={false}
        onSubmit={handleSubmit}
        onUploadFile={handleUpload}
      />,
    );

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent(
        "Selecione um arquivo EPUB ou PDF antes de enviar.",
      );
    });
    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it("envia os valores selecionados usando upload automático", async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    const handleUpload = vi
      .fn()
      .mockResolvedValue({ uploadId: "test", fileName: "amostra.epub" });
    renderWithProviders(
      <ConversionForm
        isSubmitting={false}
        onSubmit={handleSubmit}
        onUploadFile={handleUpload}
      />,
    );

    const file = new File(["conteúdo"], "amostra.epub", {
      type: "application/epub+zip",
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /converter agora/i }),
      ).toBeEnabled(),
    );
    await user.selectOptions(screen.getByLabelText(/como quer/i), "coqui");
    await user.selectOptions(
      screen.getByLabelText(/nome da voz/i),
      "tts_models/pt/cv/vits",
    );
    await user.type(screen.getByLabelText(/quais capítulos você quer/i), "1,2");
    await user.selectOptions(screen.getByLabelText(/idioma do áudio/i), "en");
    await user.click(screen.getByLabelText(/ler depois do capítulo/i));

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => {
      expect(handleSubmit).toHaveBeenCalledTimes(1);
      expect(handleSubmit.mock.calls[0][0]).toMatchObject({
        file: null,
        fileName: "amostra.epub",
        uploadId: "test",
        engine: "coqui",
        voice: "tts_models/pt/cv/vits",
        chapters: "1,2",
        footnoteMode: "chapter_end",
        language: "en",
      });
    });
  });

  it("mostra status enquanto detecta capa automaticamente", async () => {
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
      <ConversionForm
        isSubmitting={false}
        onSubmit={handleSubmit}
        onUploadFile={handleUpload}
      />,
    );

    const file = new File(["conteúdo"], "amostra.epub", {
      type: "application/epub+zip",
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    expect(screen.getByText(/detectar capa/i)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /converter agora/i }),
    ).toBeDisabled();

    resolveUpload?.({ uploadId: "auto-id", fileName: "amostra.epub" });
    await waitFor(() =>
      expect(screen.getByText(/metadados detectados/i)).toBeInTheDocument(),
    );
    expect(
      screen.getByRole("button", { name: /converter agora/i }),
    ).toBeEnabled();
  });
});
