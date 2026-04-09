/**
 * Lightweight wrappers around Tauri v2 globals.
 *
 * `tauri.conf.json` sets `withGlobalTauri: true`, so the full Tauri API is
 * available as `window.__TAURI__` inside the webview — no npm package needed.
 *
 * All functions degrade gracefully when running in a regular browser.
 */

interface TauriCore {
  invoke: (cmd: string, args?: unknown) => Promise<unknown>;
}

interface TauriEventUnlisten {
  (): void;
}

interface TauriEvent {
  listen: (
    event: string,
    handler: (e: { payload: unknown }) => void,
  ) => Promise<TauriEventUnlisten>;
}

interface TauriNotification {
  sendNotification: (options: { title: string; body?: string }) => void;
  isPermissionGranted: () => Promise<boolean>;
  requestPermission: () => Promise<string>;
}

interface TauriGlobal {
  core: TauriCore;
  event: TauriEvent;
  notification?: TauriNotification;
}

declare global {
  interface Window {
    __TAURI__?: TauriGlobal;
  }
}

/** Returns true when running inside a Tauri webview. */
export const isTauri = (): boolean =>
  typeof window !== "undefined" && Boolean(window.__TAURI__);

/** Invoke a Tauri command. Throws if not in Tauri. */
export function invoke<T>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (!window.__TAURI__) throw new Error("Not running in Tauri");
  return window.__TAURI__.core.invoke(cmd, args) as Promise<T>;
}

/**
 * Listen for a Tauri event emitted by the Rust backend.
 * Returns an unlisten function (call it in useEffect cleanup).
 * No-ops when not in Tauri.
 */
export async function listenTauri(
  event: string,
  handler: (payload: unknown) => void,
): Promise<TauriEventUnlisten> {
  if (!window.__TAURI__) return () => {};
  return window.__TAURI__.event.listen(event, (e) => handler(e.payload));
}

type TauriAny = Record<string, unknown>;

/** Check for updates via the Tauri updater plugin. */
export async function checkForUpdate(): Promise<{
  available: boolean;
  version?: string;
  body?: string;
}> {
  if (!window.__TAURI__) return { available: false };
  try {
    const tauri = window.__TAURI__ as unknown as TauriAny;
    const updater = tauri.updater as
      | {
          check: () => Promise<{
            available: boolean;
            version?: string;
            body?: string;
          }>;
        }
      | undefined;
    if (updater) {
      return await updater.check();
    }
  } catch {
    // Updater not available
  }
  return { available: false };
}

/** Install a pending update via the Tauri updater plugin. */
export async function installUpdate(): Promise<void> {
  if (!window.__TAURI__) return;
  try {
    const tauri = window.__TAURI__ as unknown as TauriAny;
    const updater = tauri.updater as
      | {
          check: () => Promise<{
            available: boolean;
            downloadAndInstall: () => Promise<void>;
          }>;
        }
      | undefined;
    if (updater) {
      const update = await updater.check();
      if (update.available) {
        await update.downloadAndInstall();
      }
    }
  } catch {
    // Update failed
  }
}

/**
 * Download a file by URL as a blob and trigger a Save dialog / browser download.
 * Works in both Tauri (WKWebView ignores `download` attr on http:// links) and
 * regular browsers (fallback identical to the blob approach).
 */
export async function downloadFile(
  url: string,
  filename: string,
): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const blob = await response.blob();
  const objectUrl = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = objectUrl;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
}

/** Send an OS notification. Only works in Tauri with notification plugin. */
export async function sendNotification(
  title: string,
  body?: string,
): Promise<void> {
  const notif = window.__TAURI__?.notification;
  if (!notif) return;
  try {
    let granted = await notif.isPermissionGranted();
    if (!granted) {
      const result = await notif.requestPermission();
      granted = result === "granted";
    }
    if (granted) {
      notif.sendNotification({ title, body });
    }
  } catch {
    // Notification not available — ignore
  }
}
