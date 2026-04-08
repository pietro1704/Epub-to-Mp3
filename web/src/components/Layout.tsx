import { PropsWithChildren } from "react";
import { useTranslations } from "../i18n/I18nProvider";
import TopBar from "./TopBar";

export default function Layout({ children }: PropsWithChildren): JSX.Element {
  const t = useTranslations();
  const footerText = t.layout.footer?.trim();
  return (
    <div className="app-shell">
      <TopBar />
      <main className="content-shell">{children}</main>
      <footer>
        {footerText && <p>{footerText}</p>}
        <p className="app-version">v{__APP_VERSION__}</p>
      </footer>
    </div>
  );
}
