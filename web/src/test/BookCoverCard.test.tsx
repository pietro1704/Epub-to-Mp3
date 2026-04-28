import { fireEvent, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import BookCoverCard from "../components/BookCoverCard";
import { renderWithProviders } from "./testUtils";

describe("BookCoverCard", () => {
  it("renders the placeholder when no cover is provided", () => {
    renderWithProviders(
      <BookCoverCard title="My Book" author="Author A" phase="idle" />,
    );
    expect(screen.getByText("My Book")).toBeInTheDocument();
    expect(screen.getByText("Author A")).toBeInTheDocument();
    expect(screen.getByText("📘")).toBeInTheDocument();
  });

  it("renders the cover image when coverUrl is provided", () => {
    renderWithProviders(
      <BookCoverCard
        title="My Book"
        author="Author A"
        coverUrl="https://example.com/cover.jpg"
        phase="success"
      />,
    );
    const img = screen.getByAltText("Book cover My Book") as HTMLImageElement;
    expect(img).toBeInTheDocument();
    expect(img.src).toBe("https://example.com/cover.jpg");
  });

  it("falls back to placeholder when the cover image fails to load", () => {
    renderWithProviders(
      <BookCoverCard
        title="My Book"
        coverUrl="https://example.com/broken.jpg"
        phase="polling"
      />,
    );
    const img = screen.getByAltText("Book cover My Book") as HTMLImageElement;
    fireEvent.error(img);
    expect(screen.getByText("📘")).toBeInTheDocument();
  });

  it("uses fallback labels when title or author are missing", () => {
    const { container } = renderWithProviders(
      <BookCoverCard phase="error" />,
    );
    expect(container.querySelector(".cover-card__title")).not.toBeEmptyDOMElement();
    expect(container.querySelector(".cover-card__author")).not.toBeEmptyDOMElement();
  });
});
