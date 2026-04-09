import { PropsWithChildren } from "react";
import { useTranslations } from "../i18n/I18nProvider";
import { isTauri } from "../lib/tauri";
import TopBar from "./TopBar";
import UpdateBanner from "./UpdateBanner";

export default function Layout({ children }: PropsWithChildren): JSX.Element {
  const t = useTranslations();
  const footerText = t.layout.footer?.trim();
  const desktop = isTauri();
  return (
    <div className={`app-shell${desktop ? " app-shell--desktop" : ""}`}>
      {!desktop && <TopBar />}
      {desktop && <UpdateBanner />}
      <main className="content-shell">{children}</main>
      <footer className="status-bar">
        <span className="status-bar__version">v{__APP_VERSION__}</span>
        {footerText && <span className="status-bar__text">{footerText}</span>}
      </footer>
    </div>
  );
}
