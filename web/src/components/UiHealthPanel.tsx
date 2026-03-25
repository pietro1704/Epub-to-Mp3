import { useEffect, useMemo, useState } from "react";
import {
  clearUiIssues,
  dismissUiIssue,
  getUiIssues,
  shouldShowUiHealthPanel,
  subscribeUiIssues,
} from "../services/uiIssueMonitor";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

export default function UiHealthPanel(): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const [issues, setIssues] = useState(() => getUiIssues());

  useEffect(() => {
    setIssues(getUiIssues());
    return subscribeUiIssues(() => setIssues(getUiIssues()));
  }, []);

  const visibleIssues = useMemo(() => issues.slice(0, 3), [issues]);

  if (!shouldShowUiHealthPanel() || visibleIssues.length === 0) {
    return null;
  }

  return (
    <section className="ui-health" aria-label={t.status.uiHealthTitle}>
      <div className="ui-health__header">
        <div>
          <div className="ui-health__eyebrow">{t.status.uiHealthTitle}</div>
          <strong>{t.status.uiHealthSubtitle(issues.length)}</strong>
        </div>
        <button
          type="button"
          className="ui-health__clear"
          onClick={() => clearUiIssues()}
        >
          {t.status.uiHealthClear}
        </button>
      </div>
      <div className="ui-health__list">
        {visibleIssues.map((issue) => (
          <article
            key={issue.id}
            className={`ui-health__item ui-health__item--${issue.severity}`}
          >
            <div className="ui-health__item-body">
              <span className="ui-health__scope">{issue.scope}</span>
              <p>{issue.message}</p>
              {issue.details && <small>{issue.details}</small>}
              <time dateTime={new Date(issue.timestamp).toISOString()}>
                {new Date(issue.timestamp).toLocaleTimeString(
                  locale === "pt" ? "pt-BR" : "en-US",
                )}
              </time>
            </div>
            <button
              type="button"
              className="ui-health__dismiss"
              onClick={() => dismissUiIssue(issue.id)}
              aria-label={t.status.uiHealthDismiss}
            >
              ×
            </button>
          </article>
        ))}
      </div>
    </section>
  );
}
