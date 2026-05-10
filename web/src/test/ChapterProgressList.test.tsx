import { describe, expect, it } from "vitest";
import { screen } from "@testing-library/react";
import ChapterProgressList from "../components/ChapterProgressList";
import { renderWithProviders } from "./testUtils";

describe("ChapterProgressList", () => {
  it("shows engine used for each chapter", () => {
    renderWithProviders(
      <ChapterProgressList
        entries={[
          {
            index: 1,
            name: "Chapter 1",
            status: "completed",
            engine: "edge",
          },
          {
            index: 2,
            name: "Chapter 2",
            status: "processing",
            engine: "piper",
          },
        ]}
      />,
      { locale: "en" },
    );

    // Engine badges render the engine name as a pill (lowercase)
    expect(screen.getAllByText("edge").length).toBeGreaterThan(0);
    expect(screen.getAllByText("piper").length).toBeGreaterThan(0);
  });

  it("shows full fallback trail when engineSequence is set", () => {
    renderWithProviders(
      <ChapterProgressList
        entries={[
          {
            index: 1,
            name: "Chapter 1",
            status: "completed",
            engine: "piper",
            engineSequence: ["edge", "kokoro", "piper"],
          },
        ]}
      />,
      { locale: "en" },
    );

    expect(screen.getAllByText("edge").length).toBeGreaterThan(0);
    expect(screen.getAllByText("kokoro").length).toBeGreaterThan(0);
    expect(screen.getAllByText("piper").length).toBeGreaterThan(0);
    // Arrow separator between engines
    expect(screen.getAllByText("→").length).toBeGreaterThan(0);
  });

  it("deduplicates consecutive identical engines in the trail", () => {
    renderWithProviders(
      <ChapterProgressList
        entries={[
          {
            index: 1,
            name: "Chapter 1",
            status: "completed",
            engineSequence: ["edge", "edge", "edge", "piper"],
          },
        ]}
      />,
      { locale: "en" },
    );

    // edge should appear once, not three times
    expect(screen.getAllByText("edge").length).toBe(1);
    expect(screen.getAllByText("piper").length).toBe(1);
  });
});
