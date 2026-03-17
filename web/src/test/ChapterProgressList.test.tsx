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
            engine: "coqui",
          },
        ]}
      />,
      { locale: "en" },
    );

    // Engine badges render the engine name as a pill (lowercase)
    expect(screen.getAllByText("edge").length).toBeGreaterThan(0);
    expect(screen.getAllByText("coqui").length).toBeGreaterThan(0);
  });
});
