import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import StreamingAudioPlayer from "../components/StreamingAudioPlayer";
import { I18nProvider } from "../i18n/I18nProvider";
import { conversionClient } from "../services/ConversionService";

describe("StreamingAudioPlayer", () => {
  const playMock = vi.fn().mockResolvedValue(undefined);
  const pauseMock = vi.fn();

  beforeEach(() => {
    localStorage.clear();
    playMock.mockClear();
    pauseMock.mockClear();
    Object.defineProperty(HTMLMediaElement.prototype, "play", {
      configurable: true,
      value: playMock,
    });
    Object.defineProperty(HTMLMediaElement.prototype, "pause", {
      configurable: true,
      value: pauseMock,
    });
  });

  it("pauses the current audio immediately before jumping chapters", async () => {
    vi.spyOn(conversionClient, "getChapterManifest").mockImplementation(
      async (_jobId, chapterIndex) => {
        if (chapterIndex === 1) {
          return {
            chunks: [{ index: 0, url: "/audio/ch1-0.mp3", text: "One" }],
          };
        }
        return null;
      },
    );

    const { container } = render(
      <I18nProvider initialLocale="en">
        <StreamingAudioPlayer
          jobId="job-jump"
          chapters={[
            { index: 1, name: "Chapter 1", status: "completed" },
            { index: 2, name: "Chapter 2", status: "processing" },
          ]}
        />
      </I18nProvider>,
    );

    await userEvent.click(screen.getByRole("button", { name: /listen now/i }));

    await waitFor(() => expect(playMock).toHaveBeenCalled());

    const selects = container.querySelectorAll("select");
    await userEvent.selectOptions(selects[1], "2");

    expect(pauseMock).toHaveBeenCalled();
    expect(
      container.querySelector(".streaming-player__chapter")?.textContent,
    ).toBe("2. Chapter 2");
  });

  it("clears the saved position when playback reaches the end of the book", async () => {
    localStorage.setItem(
      "epub-to-mp3:player-pos:job-finish",
      JSON.stringify({ chapterIndex: 1, segmentIndex: 0 }),
    );

    vi.spyOn(conversionClient, "getChapterManifest").mockResolvedValue({
      chunks: [{ index: 0, url: "/audio/ch1-0.mp3", text: "Done" }],
    });

    const { container } = render(
      <I18nProvider initialLocale="en">
        <StreamingAudioPlayer
          jobId="job-finish"
          chapters={[{ index: 1, name: "Chapter 1", status: "completed" }]}
        />
      </I18nProvider>,
    );

    await userEvent.click(screen.getByRole("button", { name: /listen now/i }));

    await waitFor(() => expect(playMock).toHaveBeenCalled());

    const audio = container.querySelector("audio");
    expect(audio).not.toBeNull();
    fireEvent.ended(audio!);

    expect(
      localStorage.getItem("epub-to-mp3:player-pos:job-finish"),
    ).toBeNull();
  });
});
