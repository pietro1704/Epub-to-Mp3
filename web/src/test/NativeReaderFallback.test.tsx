import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { renderWithProviders } from "./testUtils";
import NativeReaderFallback from "../components/NativeReaderFallback";
import { conversionClient } from "../services/ConversionService";
import { browserNativeSpeech } from "../services/BrowserNativeSpeech";
vi.mock("../services/BrowserNativeSpeech", () => ({ browserNativeSpeech: vi.fn() }));
const originalPolicy = conversionClient.getNativePlaybackPolicy;
afterEach(() => { conversionClient.getNativePlaybackPolicy = originalPolicy; vi.restoreAllMocks(); });
it("connects captured job fallback to reader controls and cancels on chapter changes", async () => {
  conversionClient.getNativePlaybackPolicy = vi.fn(async () => ({ language: "pt-BR", voice: null }));
  const speech = { speak: vi.fn(() => new Promise<void>(() => undefined)), cancel: vi.fn(), pause: vi.fn(), resume: vi.fn() };
  vi.mocked(browserNativeSpeech).mockReturnValue(speech as unknown as ReturnType<typeof browserNativeSpeech>);
  const view = renderWithProviders(<NativeReaderFallback jobId="book" chapterIndex={0} text="Chapter one" />, { locale: "en" });
  await waitFor(() => expect(screen.getByText("Listen with installed system voice")).toBeTruthy());
  fireEvent.click(screen.getByText("Listen with installed system voice"));
  expect(speech.speak).toHaveBeenCalledWith("Chapter one", "pt-BR", null, expect.any(Function));
  fireEvent.click(screen.getByText("Pause")); expect(speech.pause).toHaveBeenCalledOnce();
  fireEvent.click(screen.getByText("Resume")); expect(speech.resume).toHaveBeenCalledOnce();
  const cancellations = speech.cancel.mock.calls.length;
  view.rerender(<NativeReaderFallback jobId="book" chapterIndex={1} text="Chapter two" />);
  expect(speech.cancel.mock.calls.length).toBeGreaterThan(cancellations);
  fireEvent.click(screen.getByText("Listen with installed system voice"));
  expect(speech.speak).toHaveBeenLastCalledWith("Chapter two", "pt-BR", null, expect.any(Function));
  await act(async () => { document.dispatchEvent(new Event("play")); });
  expect(screen.getByText("Listen with installed system voice")).not.toBeDisabled();
  view.unmount();
});
it("rejects late voice, failure and retry callbacks from an old chapter identity", async () => {
  conversionClient.getNativePlaybackPolicy = vi.fn(async () => ({ language: "pt-BR", voice: null }));
  let failOld!: (error: Error) => void;
  let oldVoice!: (voice: string) => void;
  let calls = 0;
  const speech = {
    speak: vi.fn((_text: string, _language: string, _voice: string | null, onVoice: (voice: string) => void) => {
      if (++calls === 1) { oldVoice = onVoice; return new Promise<void>((_resolve, reject) => { failOld = reject; }); }
      onVoice("Current voice");
      return new Promise<void>(() => undefined);
    }),
    cancel: vi.fn(), pause: vi.fn(), resume: vi.fn(),
  };
  vi.mocked(browserNativeSpeech).mockReturnValue(speech as unknown as ReturnType<typeof browserNativeSpeech>);
  let failRetry!: (error: Error) => void;
  vi.spyOn(conversionClient, "resume").mockImplementation(() => new Promise((_resolve, reject) => { failRetry = reject; }));
  const view = renderWithProviders(<NativeReaderFallback jobId="book" chapterIndex={0} text="First" />, { locale: "en" });
  await waitFor(() => expect(screen.getByText("Listen with installed system voice")).toBeTruthy());
  fireEvent.click(screen.getByText("Listen with installed system voice"));
  fireEvent.click(screen.getByText("Retry Piper conversion"));
  view.rerender(<NativeReaderFallback jobId="book" chapterIndex={1} text="Second" />);
  fireEvent.click(screen.getByText("Listen with installed system voice"));
  await act(async () => {
    oldVoice("Stale voice");
    failOld(new Error("Stale failure"));
    failRetry(new Error("Stale retry"));
  });
  expect(screen.getByRole("status")).toHaveTextContent("Current voice");
  expect(screen.getByText("Listen with installed system voice")).toBeDisabled();
  view.unmount();
});
