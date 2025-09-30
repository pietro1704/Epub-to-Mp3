import { PropsWithChildren } from 'react';
import { useTranslations } from '../i18n/I18nProvider';
import TopBar from './TopBar';

export default function Layout({ children }: PropsWithChildren): JSX.Element {
  const t = useTranslations();
  return (
    <div className="app-shell">
      <TopBar />
      {children}
      <footer>
        <p>{t.layout.footer}</p>
      </footer>
    </div>
  );
}
