import type { PropsWithChildren, ReactElement, FC } from "react";
import { render, type RenderOptions } from "@testing-library/react";
import { I18nProvider } from "../i18n/I18nProvider";
import type { Locale } from "../i18n/translations";
import { ThemeProvider } from "../theme/ThemeProvider";

export function createProvidersWrapper(
  locale: Locale = "pt",
): FC<PropsWithChildren> {
  return function ProvidersWrapper({
    children,
  }: PropsWithChildren): JSX.Element {
    return (
      <ThemeProvider>
        <I18nProvider initialLocale={locale}>{children}</I18nProvider>
      </ThemeProvider>
    );
  };
}

interface RenderWithProvidersOptions extends Omit<RenderOptions, "wrapper"> {
  locale?: Locale;
}

export function renderWithProviders(
  ui: ReactElement,
  { locale = "pt", ...renderOptions }: RenderWithProvidersOptions = {},
) {
  const wrapper = createProvidersWrapper(locale);
  return render(ui, { wrapper, ...renderOptions });
}
