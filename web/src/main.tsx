import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import { I18nProvider } from './i18n/I18nProvider';
import { mockConversionClient } from './services/ConversionService';
import { ThemeProvider } from './theme/ThemeProvider';
import './styles/global.css';

// Use mock client in development by default
const isDev = import.meta.env.DEV;
const useMock = isDev && !import.meta.env.VITE_API_BASE;

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <ThemeProvider>
      <I18nProvider>
        <App client={useMock ? mockConversionClient : undefined} />
      </I18nProvider>
    </ThemeProvider>
  </React.StrictMode>,
);
