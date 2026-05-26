import { screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import DownloadsPanel from "../components/DownloadsPanel";
import type { DownloadAsset } from "../types/conversion";
import { renderWithProviders } from "./testUtils";

describe("DownloadsPanel chapter-name layout", () => {
  it("renders long chapter names in full without single-line clipping", () => {
    const longName =
      "04.2 - Capítulo extraordinariamente longo com subtítulo descritivo que jamais cabe em uma linha.mp3";
    const downloads: DownloadAsset[] = [
      {
        name: longName,
        url: "/api/outputs/job-test/04.2-long.mp3",
        durationSeconds: 73,
      },
    ];

    const { container } = renderWithProviders(
      <DownloadsPanel
        downloads={downloads}
        phase="success"
        onReset={vi.fn()}
        isBusy={false}
        log={[]}
      />,
    );

    const nameEl = container.querySelector(".chapter-item__name");
    expect(nameEl).not.toBeNull();
    expect(nameEl?.textContent).toBe(longName);
    expect(nameEl?.getAttribute("title")).toBe(longName);
    // Sentinel: this modifier flips the CSS rule from single-line ellipsis
    // truncation to the 2-line clamp used across the app (mirrors the
    // EbookReaderPanel fix from slice 9). Removing it silently regresses
    // visible chapter names back to "Capítulo extraord…".
    expect(nameEl?.classList.contains("chapter-item__name--multiline")).toBe(
      true,
    );
    // The Download CTA must stay visible alongside long names, not pushed
    // off-row by an unconstrained title.
    expect(
      screen.getByRole("link", { name: /Baixar MP3|Download MP3/i }),
    ).toBeInTheDocument();
  });
});
