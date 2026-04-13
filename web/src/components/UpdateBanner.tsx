import { useEffect, useState } from "react";
import { useTranslations } from "../i18n/I18nProvider";
import { isTauri, listenTauri, installUpdate } from "../lib/tauri";

interface UpdateInfo {
  version: string;
  body: string;
}

export default function UpdateBanner(): JSX.Element | null {
  const t = useTranslations();
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [installing, setInstalling] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [installError, setInstallError] = useState<string | null>(null);

  useEffect(() => {
    if (!isTauri()) return;

    let unsub1: (() => void) | undefined;
    let unsub2: (() => void) | undefined;

    // Listen for auto-check result from Rust startup
    listenTauri("tauri-update-available", (payload) => {
      const info = payload as UpdateInfo;
      if (info?.version) {
        setUpdate(info);
        setDismissed(false);
        setInstallError(null);
      }
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
            setInstallError(null);
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
    setInstallError(null);
    try {
      await installUpdate();
    } catch {
      setInstallError(t.layout.updateInstallError);
    } finally {
      setInstalling(false);
    }
  };

  return (
    <div className="update-banner">
      <span>{t.layout.updateAvailable(update.version)}</span>
      <button type="button" onClick={handleInstall} disabled={installing}>
        {installing ? t.layout.updateInstalling : t.layout.updateInstall}
      </button>
      <button
        type="button"
        className="update-banner__dismiss"
        onClick={() => setDismissed(true)}
        aria-label={t.layout.updateDismiss}
      >
        &times;
      </button>
      {installError && <span role="alert">{installError}</span>}
    </div>
  );
}
