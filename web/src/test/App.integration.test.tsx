import { act, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { renderWithProviders } from "./testUtils";
import type { ConversionClient } from "../services/ConversionService";
import type { JobSnapshot } from "../types/conversion";

function setTauriGlobal(value: unknown) {
  Object.defineProperty(window, "__TAURI__", {
    configurable: true,
    writable: true,
    value,
  });
}

afterEach(() => {
  setTauriGlobal(undefined);
});

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
    const fileInput = await screen.findByLabelText(
      /arquivo do livro/i,
      {},
      { timeout: 5000 },
    );
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
    const fileInput = await screen.findByLabelText(
      /arquivo do livro/i,
      {},
      { timeout: 5000 },
    );
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

  it("shows startup panel again when the Tauri sidecar restarts", async () => {
    const listeners = new Map<string, (payload: unknown) => void>();
    setTauriGlobal({
      core: {
        invoke: vi.fn().mockResolvedValue([]),
      },
      event: {
        listen: vi
          .fn()
          .mockImplementation(
            async (
              event: string,
              handler: (e: { payload: unknown }) => void,
            ) => {
              listeners.set(event, (payload: unknown) => handler({ payload }));
              return () => listeners.delete(event);
            },
          ),
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        json: vi.fn().mockResolvedValue({ status: "starting" }),
      }),
    );

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };

    await act(async () => {
      renderWithProviders(<App client={client} />, { locale: "en" });
    });

    expect(screen.getByText("Starting conversion engine…")).toBeInTheDocument();

    await act(async () => {
      listeners.get("tauri-startup-ready")?.(undefined);
    });

    await waitFor(() =>
      expect(
        screen.queryByText("Starting conversion engine…"),
      ).not.toBeInTheDocument(),
    );

    await act(async () => {
      listeners.get("tauri-server-restarting")?.(undefined);
      listeners.get("tauri-server-log")?.("Restarting sidecar");
    });

    expect(screen.getByText("Starting conversion engine…")).toBeInTheDocument();
    expect(screen.getByText("Restarting sidecar")).toBeInTheDocument();
  });
});
