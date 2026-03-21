import { act, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import App from "../App";
import { renderWithProviders } from "./testUtils";
import type { ConversionClient } from "../services/ConversionService";
import type { JobSnapshot } from "../types/conversion";

describe("App integration", () => {
  it("runs full conversion flow with a custom client", async () => {
    const user = userEvent.setup();
    const submit = vi.fn().mockResolvedValue({ jobId: "job-777" });
    const poll = vi
      .fn()
      .mockImplementation(
        async (
          _jobId: string,
          options?: { onSnapshot?: (snapshot: JobSnapshot) => void },
        ) => {
          options?.onSnapshot?.({
            jobId: "job-777",
            state: "running",
            events: ["File loaded", "Synthesizing chapter 1"],
            detectedLanguage: "pt-BR",
            chaptersTotal: 2,
            chaptersCompleted: 1,
            currentChapter: "Chapter 1",
            progressPercent: 45,
          });
          return {
            jobId: "job-777",
            state: "finished",
            outputs: [
              {
                name: "Chapter 1.mp3",
                url: "https://cdn.example/audio-1.mp3",
              },
              {
                name: "Chapter 2.mp3",
                url: "https://cdn.example/audio-2.mp3",
              },
            ],
            detectedLanguage: "pt-BR",
            chaptersTotal: 2,
            chaptersCompleted: 2,
            currentChapter: "Chapter 2",
            progressPercent: 100,
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    await act(async () => {
      renderWithProviders(<App client={client} />);
    });

    const file = new File(["ebook"], "historia.pdf", {
      type: "application/pdf",
    });
    const fileInput = await screen.findByLabelText(/arquivo do livro/i);
    await user.upload(fileInput, file);

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    expect(submit).toHaveBeenCalledWith(
      expect.objectContaining({
        file,
        fileName: "historia.pdf",
      }),
    );
    await waitFor(() =>
      expect(poll).toHaveBeenCalledWith("job-777", expect.any(Object)),
    );
  });

  it("reuses automatic upload and avoids resending the file", async () => {
    const user = userEvent.setup();
    const submit = vi.fn().mockResolvedValue({ jobId: "job-999" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "job-999",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);
    const upload = vi.fn().mockResolvedValue({
      uploadId: "upload-123",
      fileName: "historia.pdf",
      bookTitle: "Historia",
      bookAuthor: "Autor Teste",
      coverUrl: "/covers/historia.jpg",
    });

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
      upload,
    };

    await act(async () => {
      renderWithProviders(<App client={client} />);
    });

    const file = new File(["ebook"], "historia.pdf", {
      type: "application/pdf",
    });
    const fileInput = await screen.findByLabelText(/arquivo do livro/i);
    await user.upload(fileInput, file);
    await waitFor(() => expect(upload).toHaveBeenCalledTimes(1));

    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /converter agora/i }),
      ).toBeEnabled(),
    );
    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => {
      expect(submit).toHaveBeenCalledTimes(1);
      expect(submit).toHaveBeenCalledWith(
        expect.objectContaining({
          file: null,
          uploadId: "upload-123",
          fileName: "historia.pdf",
          bookTitle: "Historia",
          bookAuthor: "Autor Teste",
          coverUrl: "/covers/historia.jpg",
        }),
      );
    });
  });
});
