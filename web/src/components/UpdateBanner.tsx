import { useEffect, useState } from "react";
import { isTauri, listenTauri, installUpdate } from "../lib/tauri";

interface UpdateInfo {
  version: string;
  body: string;
}

export default function UpdateBanner(): JSX.Element | null {
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [installing, setInstalling] = useState(false);
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    if (!isTauri()) return;

    let unsub1: (() => void) | undefined;
    let unsub2: (() => void) | undefined;

    // Listen for auto-check result from Rust startup
    listenTauri("tauri-update-available", (payload) => {
      const info = payload as UpdateInfo;
      if (info?.version) setUpdate(info);
    }).then((fn) => {
      unsub1 = fn;
    });

    // Listen for manual "Check for Updates" menu click
    listenTauri("tauri-check-update", () => {
      // Trigger a check from JS side
      import("../lib/tauri").then(({ checkForUpdate }) => {
        checkForUpdate().then((result) => {
          if (result.available && result.version) {
            setUpdate({ version: result.version, body: result.body ?? "" });
            setDismissed(false);
          }
        });
      });
    }).then((fn) => {
      unsub2 = fn;
    });

    return () => {
      unsub1?.();
      unsub2?.();
    };
  }, []);

  if (!update || dismissed) return null;

  const handleInstall = async () => {
    setInstalling(true);
    try {
      await installUpdate();
    } catch {
      setInstalling(false);
    }
  };

  return (
    <div className="update-banner">
      <span>Update v{update.version} available</span>
      <button onClick={handleInstall} disabled={installing}>
        {installing ? "Installing..." : "Install & Restart"}
      </button>
      <button
        className="update-banner__dismiss"
        onClick={() => setDismissed(true)}
        aria-label="Dismiss"
      >
        &times;
      </button>
    </div>
  );
}
