import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import ConversionForm from "../components/ConversionForm";
import type { UploadResponse } from "../services/ConversionService";
import { renderWithProviders } from "./testUtils";

describe("ConversionForm", () => {
  it("shows error message when no file is selected", async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn();
    const handleUpload = vi
      .fn()
      .mockResolvedValue({ uploadId: "test", fileName: "sample.epub" });
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

  it("submits selected values using automatic upload", async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    const handleUpload = vi
      .fn()
      .mockResolvedValue({ uploadId: "test", fileName: "sample.epub" });
    renderWithProviders(
      <ConversionForm
        isSubmitting={false}
        onSubmit={handleSubmit}
        onUploadFile={handleUpload}
      />,
    );

    const file = new File(["content"], "sample.epub", {
      type: "application/epub+zip",
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /converter agora/i }),
      ).toBeEnabled(),
    );
    await user.selectOptions(screen.getByLabelText(/como quer/i), "piper");
    await user.selectOptions(
      screen.getByLabelText(/nome da voz/i),
      "pt_BR-faber-medium.onnx",
    );
    await user.type(screen.getByLabelText(/quais capítulos você quer/i), "1,2");
    await user.selectOptions(screen.getByLabelText(/idioma do áudio/i), "en");
    await user.click(screen.getByLabelText(/ler depois do capítulo/i));

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => {
      expect(handleSubmit).toHaveBeenCalledTimes(1);
      expect(handleSubmit.mock.calls[0][0]).toMatchObject({
        file: null,
        fileName: "sample.epub",
        uploadId: "test",
        engine: "piper",
        voice: "pt_BR-faber-medium.onnx",
        chapters: "1,2",
        footnoteMode: "chapter_end",
        language: "en",
      });
    });
  }, 10000);

  it("shows status while auto-detecting cover", async () => {
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

    const file = new File(["content"], "sample.epub", {
      type: "application/epub+zip",
    });

    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    expect(screen.getByText(/detectar capa/i)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /converter agora/i }),
    ).toBeDisabled();

    resolveUpload?.({ uploadId: "auto-id", fileName: "sample.epub" });
    await waitFor(() =>
      expect(screen.getByText(/metadados detectados/i)).toBeInTheDocument(),
    );
    expect(
      screen.getByRole("button", { name: /converter agora/i }),
    ).toBeEnabled();
  });

  it("ships character-voice toggle on by default and submits the new fields", async () => {
    const user = userEvent.setup();
    const handleSubmit = vi.fn().mockResolvedValue(undefined);
    const handleUpload = vi
      .fn()
      .mockResolvedValue({ uploadId: "voices", fileName: "sample.epub" });
    renderWithProviders(
      <ConversionForm
        isSubmitting={false}
        onSubmit={handleSubmit}
        onUploadFile={handleUpload}
      />,
    );

    const file = new File(["content"], "sample.epub", {
      type: "application/epub+zip",
    });
    await user.upload(screen.getByLabelText(/arquivo do livro/i), file);
    await waitFor(() => expect(handleUpload).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /converter agora/i }),
      ).toBeEnabled(),
    );

    // Toggle is rendered, on by default, and reveals the two voice selects.
    const toggle = screen.getByLabelText(
      /vozes diferentes para narrador e personagens/i,
    );
    expect(toggle).toBeChecked();
    expect(screen.getByLabelText(/voz do narrador/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/voz dos personagens/i)).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => expect(handleSubmit).toHaveBeenCalledTimes(1));
    expect(handleSubmit.mock.calls[0][0]).toMatchObject({
      enableCharacterVoices: true,
    });
  }, 10000);
});
