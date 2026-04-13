import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  downloadFile,
  installUpdate,
  isTauri,
  sendNotification,
} from "../lib/tauri";

// Helper to set window.__TAURI__
function setTauri(value: unknown) {
  Object.defineProperty(window, "__TAURI__", {
    value,
    writable: true,
    configurable: true,
  });
}

afterEach(() => {
  setTauri(undefined);
  vi.restoreAllMocks();
});

describe("isTauri", () => {
  it("returns false when __TAURI__ is not set", () => {
    setTauri(undefined);
    expect(isTauri()).toBe(false);
  });

  it("returns true when __TAURI__ is set", () => {
    setTauri({ core: {}, event: {} });
    expect(isTauri()).toBe(true);
  });
});

describe("downloadFile", () => {
  beforeEach(() => {
    // Mock URL API
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn(() => "blob:test-url"),
      revokeObjectURL: vi.fn(),
    });

    // Mock document.body.appendChild / removeChild / click
    const anchor = {
      href: "",
      download: "",
      click: vi.fn(),
    };
    vi.spyOn(document, "createElement").mockReturnValue(
      anchor as unknown as HTMLElement,
    );
    vi.spyOn(document.body, "appendChild").mockReturnValue(
      anchor as unknown as Node,
    );
    vi.spyOn(document.body, "removeChild").mockReturnValue(
      anchor as unknown as Node,
    );
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("fetches the URL and triggers a download", async () => {
    const blob = new Blob(["audio-data"]);
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        headers: { get: () => null },
        blob: vi.fn().mockResolvedValue(blob),
      }),
    );

    await downloadFile("http://localhost/test.mp3", "test.mp3");

    expect(fetch).toHaveBeenCalledWith("http://localhost/test.mp3");
    expect(URL.createObjectURL).toHaveBeenCalledWith(blob);
  });

  it("throws when the server returns a non-OK status", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        headers: { get: () => null },
      }),
    );

    await expect(
      downloadFile("http://localhost/missing.mp3", "missing.mp3"),
    ).rejects.toThrow("HTTP 404");
  });

  it("reports streaming progress when content-length is available", async () => {
    const chunk = new Uint8Array([1, 2, 3, 4]);
    const mockReader = {
      read: vi
        .fn()
        .mockResolvedValueOnce({ done: false, value: chunk })
        .mockResolvedValueOnce({ done: true, value: undefined }),
    };
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        headers: { get: () => "4" },
        body: { getReader: () => mockReader },
      }),
    );

    const onProgress = vi.fn();
    await downloadFile("http://localhost/test.mp3", "test.mp3", onProgress);

    expect(onProgress).toHaveBeenCalledWith(4, 4);
  });
});

describe("sendNotification", () => {
  it("does nothing when __TAURI__ is not set", async () => {
    setTauri(undefined);
    await expect(sendNotification("Title", "Body")).resolves.toBeUndefined();
  });

  it("does nothing when notification plugin is absent", async () => {
    setTauri({ core: {}, event: {} }); // no .notification
    await expect(sendNotification("Title")).resolves.toBeUndefined();
  });

  it("sends notification when permission already granted", async () => {
    const sendNotificationMock = vi.fn();
    setTauri({
      core: {},
      event: {},
      notification: {
        isPermissionGranted: vi.fn().mockResolvedValue(true),
        requestPermission: vi.fn(),
        sendNotification: sendNotificationMock,
      },
    });

    await sendNotification("Done!", "Your audiobook is ready");
    expect(sendNotificationMock).toHaveBeenCalledWith({
      title: "Done!",
      body: "Your audiobook is ready",
    });
  });

  it("requests permission then sends when not yet granted", async () => {
    const sendNotificationMock = vi.fn();
    setTauri({
      core: {},
      event: {},
      notification: {
        isPermissionGranted: vi.fn().mockResolvedValue(false),
        requestPermission: vi.fn().mockResolvedValue("granted"),
        sendNotification: sendNotificationMock,
      },
    });

    await sendNotification("Done!");
    expect(sendNotificationMock).toHaveBeenCalledWith({
      title: "Done!",
      body: undefined,
    });
  });
});

describe("installUpdate", () => {
  it("does nothing when updater plugin is absent", async () => {
    setTauri({ core: {}, event: {} });
    await expect(installUpdate()).resolves.toBeUndefined();
  });

  it("downloads and installs when an update is available", async () => {
    const downloadAndInstall = vi.fn().mockResolvedValue(undefined);
    setTauri({
      core: {},
      event: {},
      updater: {
        check: vi.fn().mockResolvedValue({
          available: true,
          downloadAndInstall,
        }),
      },
    });

    await expect(installUpdate()).resolves.toBeUndefined();
    expect(downloadAndInstall).toHaveBeenCalledTimes(1);
  });

  it("propagates install failures to the caller", async () => {
    const downloadAndInstall = vi
      .fn()
      .mockRejectedValue(new Error("install failed"));
    setTauri({
      core: {},
      event: {},
      updater: {
        check: vi.fn().mockResolvedValue({
          available: true,
          downloadAndInstall,
        }),
      },
    });

    await expect(installUpdate()).rejects.toThrow("install failed");
  });
});
