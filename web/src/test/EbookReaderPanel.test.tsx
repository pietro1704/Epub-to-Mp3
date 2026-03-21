import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import EbookReaderPanel from "../components/EbookReaderPanel";
import { conversionClient } from "../services/ConversionService";
import { renderWithProviders } from "./testUtils";

describe("EbookReaderPanel", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    window.localStorage.clear();
  });

  it("loads full text and follows the active audio chapter", async () => {
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      bookTitle: "Livro Teste",
      bookAuthor: "Autora Teste",
      chapters: [
        {
          index: 0,
          name: "Prólogo",
          text: "Introdução curta.",
          charCount: 17,
        },
        {
          index: 1,
          name: "Capítulo 1",
          text: "Primeiro trecho. Segundo trecho em destaque. Final.",
          charCount: 51,
        },
      ],
    });

    renderWithProviders(
      <EbookReaderPanel
        jobId="job-reader"
        playback={{
          chapterIndex: 1,
          segmentIndex: 2,
          segmentText: "Segundo trecho em destaque.",
          isPlaying: true,
          started: true,
          waiting: false,
        }}
      />,
    );

    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Capítulo 1" }),
      ).toBeInTheDocument(),
    );
    expect(screen.getByText("Segundo trecho em destaque.")).toBeInTheDocument();
    expect(screen.getByText(/Segmento 3/i)).toBeInTheDocument();
  });

  it("lets the user disable follow-audio and manually switch chapters", async () => {
    const user = userEvent.setup();
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 0,
          name: "Chapter 0",
          text: "Alpha text.",
          charCount: 11,
        },
        {
          index: 1,
          name: "Chapter 1",
          text: "Beta text.",
          charCount: 10,
        },
      ],
    });

    renderWithProviders(
      <EbookReaderPanel
        jobId="job-reader"
        playback={{
          chapterIndex: 1,
          segmentIndex: 0,
          segmentText: "Beta text.",
          isPlaying: true,
          started: true,
          waiting: false,
        }}
      />,
      { locale: "en" },
    );

    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Chapter 1" }),
      ).toBeInTheDocument(),
    );

    await user.click(screen.getByRole("checkbox"));
    await user.click(screen.getByRole("button", { name: /Chapter 0/i }));

    expect(
      screen.getByRole("heading", { name: "Chapter 0" }),
    ).toBeInTheDocument();
    expect(screen.getByText(/Manual reading/i)).toBeInTheDocument();
  });

  it("shows a single read-book CTA and calls the start handler", async () => {
    const user = userEvent.setup();
    const onRequestStart = vi.fn();
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 1,
          name: "Capítulo 1",
          text: "Texto.",
          charCount: 6,
        },
      ],
    });

    renderWithProviders(
      <EbookReaderPanel jobId="job-reader" onRequestStart={onRequestStart} />,
    );

    const button = await screen.findByRole("button", { name: /Ler livro/i });
    await user.click(button);

    expect(onRequestStart).toHaveBeenCalledTimes(1);
  });
});
