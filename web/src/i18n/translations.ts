import type { EngineOption, FootnoteMode } from '../types/conversion';

export type Locale = 'en' | 'pt';

export interface EngineOptionText {
  value: EngineOption;
  label: string;
  help: string;
}

export interface FootnoteOptionText {
  value: FootnoteMode;
  title: string;
  description: string;
}

export interface TopBarText {
  ariaLabel: string;
  themeLabel: string;
  themeLight: string;
  themeDark: string;
  localeLabel: string;
  localeEnglish: string;
  localePortuguese: string;
}

export interface HeroHighlight {
  title: string;
  description: string;
}

export interface HeroText {
  badge: string;
  title: string;
  subtitle: string;
  highlights: HeroHighlight[];
}

export interface TabsText {
  setup: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
  };
  progress: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
  };
  downloads: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
    footer: string;
  };
}

export interface FormText {
  fileLabel: string;
  fileHint: string;
  useSampleButton: string;
  engineLabel: string;
  engineOptions: EngineOptionText[];
  defaultVoiceLabel: string;
  multilingualSupportLabel: string;
  multilingualYes: string;
  multilingualNo: string;
  autoLanguageLabel: string;
  manualLanguageLabel: string;
  voiceLabel: string;
  voicePlaceholder: string;
  voiceHint: string;
  voiceMultilingualHint: string;
  chaptersLabel: string;
  chaptersPlaceholder: string;
  chaptersHint: string;
  priorityLabel: string;
  priorityPlaceholder: string;
  priorityHint: string;
  footnoteLegend: string;
  footnoteOptions: FootnoteOptionText[];
  languageLabel: string;
  languagePlaceholder: string;
  languageHint: string;
  languageNotRequired: string;
  languageOptions: Record<string, string>;
  availableLanguagesLabel: string;
  errorNoFile: string;
  submitIdle: string;
  submitBusy: string;
}

export interface StatusText {
  phases: Record<'idle' | 'submitting' | 'polling' | 'success' | 'error' | 'cancelling' | 'cancelled', string>;
  jobLabel: (jobId: string) => string;
  placeholder: string;
  errorPrefix: string;
  toggleShow: string;
  toggleHide: string;
  etaLabel: string;
  etaCalculating: string;
  etaSoon: string;
  etaDone: string;
  cancelButton: string;
  cancelButtonPending: string;
  progressLabel: string;
  summaryTitle: string;
  summaryLanguage: string;
  summaryChapters: string;
  summaryCurrent: string;
  summaryProgress: string;
}

export interface DownloadsText {
  placeholder: string;
  resetWithDownloads: string;
  resetWithoutDownloads: string;
  audioNotSupported: string;
  downloadChapter: string;
  downloadZip: string;
  downloadZipHint: (chapterCount: number) => string;
  orIndividual: string;
}

export interface LayoutText {
  footer: string;
}

export interface FlowMessages {
  start: string;
  jobCreated: (jobId: string) => string;
  resuming: string;
  completion: (count: number) => string;
  failure: (message: string) => string;
  error: (message: string) => string;
  defaultFailure: string;
  defaultError: string;
  cancelRequested: string;
  cancelled: string;
  cancelFailed: (message: string) => string;
}

export interface Translations {
  locale: Locale;
  topBar: TopBarText;
  hero: HeroText;
  tabs: TabsText;
  form: FormText;
  status: StatusText;
  downloads: DownloadsText;
  layout: LayoutText;
  flow: FlowMessages;
}

export const translations: Record<Locale, Translations> = {
  pt: {
    locale: 'pt',
    topBar: {
      ariaLabel: 'Preferências de tema e idioma',
      themeLabel: 'Tema',
      themeLight: 'Claro',
      themeDark: 'Escuro',
      localeLabel: 'Idioma',
      localeEnglish: 'Inglês',
      localePortuguese: 'Português',
    },
    hero: {
      badge: 'Livro em áudio',
      title: 'Transforme seu EPUB ou PDF em MP3 com poucos cliques',
      subtitle:
        'Envie o arquivo, escolha a voz preferida e deixe o serviço Python narrar a história para você ouvir onde quiser.',
      highlights: [
        {
          title: 'Edge → XTTS → Piper',
          description: 'Escolhemos automaticamente o motor mais estável para manter qualidade e velocidade.',
        },
        {
          title: 'Multi-idioma real',
          description: 'Detectamos mudanças de idioma no texto e alternamos a voz sem precisar configurar nada.',
        },
        {
          title: 'Conversões retomáveis',
          description: 'O cache inteligente retoma jobs interrompidos e evita refazer capítulos já prontos.',
        },
      ],
    },
    tabs: {
      setup: {
        label: '1. Preparar conversão',
        description: 'Envie o livro e escolha voz, notas e capítulos.',
        panelTitle: 'Envie seu livro',
        panelDescription: 'Faça o upload e escolha como o áudio deve soar.',
      },
      progress: {
        label: '2. Acompanhar andamento',
        description: 'Veja o passo a passo enquanto o serviço Python trabalha.',
        panelTitle: 'Status da conversão',
        panelDescription: 'Aqui ficam as mensagens mais recentes.',
      },
      downloads: {
        label: '3. Ouvir e baixar',
        description: 'Os capítulos prontos aparecem aqui para download imediato.',
        panelTitle: 'Seus arquivos MP3',
        panelDescription: 'Baixe os capítulos convertidos ou inicie outra conversão.',
        footer: '',
      },
    },
    form: {
      fileLabel: 'Arquivo do livro (EPUB ou PDF)',
      fileHint: 'Escolha o arquivo do seu computador. Usamos apenas para gerar o áudio.',
      useSampleButton: 'Usar livro de exemplo',
      engineLabel: 'Como quer que a voz soe?',
      engineOptions: [
        {
          value: 'edge',
          label: 'Edge (padrão)',
          help: 'Vozes de nuvem da Microsoft. Ótima qualidade e sotaque natural.',
        },
        {
          value: 'auto',
          label: 'Automático (mais rápido)',
          help: 'Escolhe Edge/Coqui/Piper por capítulo para máxima velocidade.',
        },
        {
          value: 'piper',
          label: 'Piper (local)',
          help: 'Modelos PT/EN incluídos. Funciona offline, mas exige escolher o idioma.',
        },
        {
          value: 'coqui',
          label: 'Coqui (personalizado)',
          help: 'Motor multilíngue (XTTS ou VITS). Detecta idioma automaticamente.',
        },
      ],
      defaultVoiceLabel: 'Voz padrão com suporte a vários idiomas',
      multilingualSupportLabel: 'Suporte multilíngue',
      multilingualYes: 'Sim, detecta automaticamente.',
      multilingualNo: 'Não, escolha o idioma manualmente.',
      autoLanguageLabel: 'Detecção automática de idioma ativada.',
      manualLanguageLabel: 'Selecione o idioma para esta conversão.',
      voiceLabel: 'Nome da voz (opcional)',
      voicePlaceholder: 'Deixe vazio para usar a voz padrão',
      voiceHint: 'Você pode escolher uma voz específica se souber o nome dela. Caso contrário, mantenha em branco.',
      voiceMultilingualHint: 'Esta voz suporta múltiplos idiomas automaticamente.',
      chaptersLabel: 'Quais capítulos você quer ouvir? (opcional)',
      chaptersPlaceholder: 'Ex.: 1,2 ou 3.1 (deixe em branco para todos)',
      chaptersHint: 'Separe os números por vírgula. O app usa todos os capítulos se você deixar vazio.',
      priorityLabel: 'Quais capítulos devem ter prioridade? (opcional)',
      priorityPlaceholder: 'Ex.: 1,4 ou Prólogo (sintaxe igual ao campo acima)',
      priorityHint: 'Capítulos listados aqui são narrados primeiro, depois o restante segue na ordem original.',
      footnoteLegend: 'Como tratar as notas de rodapé?',
      footnoteOptions: [
        {
          value: 'inline',
          title: 'Ler junto com a história',
          description: 'As notas entram na mesma hora do texto. Ideal para quem não quer perder detalhes.',
        },
        {
          value: 'chapter_end',
          title: 'Ler depois do capítulo',
          description: 'Guarda as notas para o final de cada capítulo. O áudio principal fica mais limpo.',
        },
        {
          value: 'skip',
          title: 'Não ler as notas',
          description: 'Ignora notas de rodapé por completo. Use se elas não forem importantes para você.',
        },
      ],
      languageLabel: 'Idioma do áudio',
      languagePlaceholder: 'Selecione o idioma principal',
      languageHint: 'Escolha o idioma quando o motor não fizer detecção automática.',
      languageNotRequired: 'Este motor detecta o idioma sozinho.',
      languageOptions: {
        auto: 'Automático',
        pt: 'Português (Brasil)',
        en: 'Inglês (Estados Unidos)',
        es: 'Espanhol (América Latina)',
        fr: 'Francês',
        de: 'Alemão',
      },
      availableLanguagesLabel: 'Idiomas disponíveis',
      errorNoFile: 'Selecione um arquivo EPUB ou PDF antes de enviar.',
      submitIdle: 'Converter agora',
      submitBusy: 'Gerando áudio…',
    },
    status: {
      phases: {
        idle: 'Pronto para começar',
        submitting: 'Enviando arquivo…',
        polling: 'Lendo e convertendo…',
        success: 'Tudo pronto!',
        error: 'Ops, algo deu errado',
        cancelling: 'Cancelando…',
        cancelled: 'Cancelado',
      },
      jobLabel: (jobId: string) => `Código do pedido: ${jobId}`,
      placeholder: 'Envie um arquivo para acompanhar o passo a passo aqui.',
      errorPrefix: 'Detalhes: {message}',
      toggleShow: 'Mostrar saída do terminal',
      toggleHide: 'Ocultar saída do terminal',
      etaLabel: 'Tempo estimado',
      etaCalculating: 'calculando…',
      etaSoon: 'quase pronto',
      etaDone: 'concluído',
      cancelButton: 'Parar conversão',
      cancelButtonPending: 'Cancelando…',
      progressLabel: 'Progresso geral',
      summaryTitle: 'Resumo da execução',
      summaryLanguage: 'Idioma detectado',
      summaryChapters: 'Capítulos totais',
      summaryCurrent: 'Capítulo em andamento',
      summaryProgress: 'Progresso',
    },
    downloads: {
      placeholder: 'Assim que a conversão terminar, os áudios ficam disponíveis aqui para ouvir ou baixar.',
      resetWithDownloads: 'Começar uma nova conversão',
      resetWithoutDownloads: 'Limpar tudo',
      audioNotSupported: 'Seu navegador não suporta reprodução de áudio.',
      downloadChapter: '⬇ Baixar MP3',
      downloadZip: 'Baixar Audiolivro Completo (ZIP)',
      downloadZipHint: (count: number) => `Contém ${count} ${count === 1 ? 'capítulo' : 'capítulos'} em MP3`,
      orIndividual: 'Ou baixe/ouça os capítulos individualmente',
    },
    layout: {
      footer: '',
    },
    flow: {
      start: 'Enviando arquivo para o servidor…',
      jobCreated: (jobId: string) => `Pedido ${jobId} recebido. Aguardando narração…`,
      resuming: '🔄 Retomando conversão interrompida…',
      completion: (count: number) => `Conversão finalizada com ${count} arquivos de áudio.`,
      failure: (message: string) => `Pedido com erro: ${message}`,
      error: (message: string) => `Erro: ${message}`,
      defaultFailure: 'A conversão falhou',
      defaultError: 'Erro inesperado',
      cancelRequested: '🛑 Cancelamento solicitado. Concluindo passo atual…',
      cancelled: 'Pedido cancelado pelo usuário.',
      cancelFailed: (message: string) => `Não foi possível cancelar: ${message || 'tente novamente'}`,
    },
  },
  en: {
    locale: 'en',
    topBar: {
      ariaLabel: 'Theme and language preferences',
      themeLabel: 'Theme',
      themeLight: 'Light',
      themeDark: 'Dark',
      localeLabel: 'Language',
      localeEnglish: 'English',
      localePortuguese: 'Portuguese',
    },
    hero: {
      badge: 'Audio book',
      title: 'Turn your EPUB or PDF into MP3 in just a few clicks',
      subtitle:
        'Upload the file, pick a voice you like, and let the Python service narrate the story so you can listen anywhere.',
      highlights: [
        {
          title: 'Edge → XTTS → Piper',
          description: 'Automatically picks the most reliable engine to keep quality and speed high.',
        },
        {
          title: 'True multilingual',
          description: 'Detects language changes per chapter and switches voices with zero configuration.',
        },
        {
          title: 'Resume conversions',
          description: 'Smart caching resumes interrupted jobs and skips chapters already rendered.',
        },
      ],
    },
    tabs: {
      setup: {
        label: '1. Prepare conversion',
        description: 'Upload the book and choose voice, footnotes, and chapters.',
        panelTitle: 'Upload your book',
        panelDescription: 'Send the file and define how the audio should sound.',
      },
      progress: {
        label: '2. Track progress',
        description: 'Follow each step while the Python service works.',
        panelTitle: 'Conversion status',
        panelDescription: 'The latest messages show up here.',
      },
      downloads: {
        label: '3. Listen & download',
        description: 'Finished chapters become available for instant download.',
        panelTitle: 'Your MP3 files',
        panelDescription: 'Download the chapters or start another conversion.',
        footer: '',
      },
    },
    form: {
      fileLabel: 'Book file (EPUB or PDF)',
      fileHint: 'Pick a file from your computer. We only use it to generate the audio.',
      useSampleButton: 'Use sample book',
      engineLabel: 'How should the voice sound?',
      engineOptions: [
        {
          value: 'edge',
          label: 'Edge (default)',
          help: 'Microsoft cloud voices with natural accents.',
        },
        {
          value: 'auto',
          label: 'Auto (fastest)',
          help: 'Chooses Edge/Coqui/Piper per chapter for maximum speed.',
        },
        {
          value: 'piper',
          label: 'Piper (local)',
          help: 'Bundled PT/EN voices. Works offline but needs a chosen language.',
        },
        {
          value: 'coqui',
          label: 'Coqui (custom)',
          help: 'XTTS/VITS voices with automatic language detection.',
        },
      ],
      defaultVoiceLabel: 'Default voice with multi-language support',
      multilingualSupportLabel: 'Multilingual support',
      multilingualYes: 'Yes, language is detected automatically.',
      multilingualNo: 'No, pick the language manually.',
      autoLanguageLabel: 'Automatic language detection enabled.',
      manualLanguageLabel: 'Select the language for this conversion.',
      voiceLabel: 'Voice name (optional)',
      voicePlaceholder: 'Leave blank to use the default voice',
      voiceHint: 'Type a specific voice name if you know it. Otherwise keep it blank.',
      voiceMultilingualHint: 'This voice supports multiple languages automatically.',
      chaptersLabel: 'Which chapters do you want? (optional)',
      chaptersPlaceholder: 'Example: 1,2 or 3.1 (leave blank for all)',
      chaptersHint: 'Separate numbers with commas. All chapters are used if left blank.',
      priorityLabel: 'Prioritize specific chapters? (optional)',
      priorityPlaceholder: 'Example: 1,4 or Prologue (same syntax as above)',
      priorityHint: 'Chapters listed here will be rendered first, then the remaining ones follow the original order.',
      footnoteLegend: 'How should we read footnotes?',
      footnoteOptions: [
        {
          value: 'inline',
          title: 'Read with the story',
          description: 'Keep footnotes in place so you never miss details.',
        },
        {
          value: 'chapter_end',
          title: 'Read after each chapter',
          description: 'Collect footnotes at the end. The main audio stays cleaner.',
        },
        {
          value: 'skip',
          title: 'Skip footnotes',
          description: 'Ignore footnotes completely if they are not important to you.',
        },
      ],
      languageLabel: 'Audio language',
      languagePlaceholder: 'Choose the primary language',
      languageHint: 'Select the language whenever the engine cannot switch automatically.',
      languageNotRequired: 'This engine detects the language automatically.',
      languageOptions: {
        auto: 'Automatic',
        pt: 'Portuguese (Brazil)',
        en: 'English (United States)',
        es: 'Spanish (Latin America)',
        fr: 'French',
        de: 'German',
      },
      availableLanguagesLabel: 'Available languages',
      errorNoFile: 'Choose an EPUB or PDF file before converting.',
      submitIdle: 'Convert now',
      submitBusy: 'Generating audio…',
    },
    status: {
      phases: {
        idle: 'Ready to start',
        submitting: 'Uploading file…',
        polling: 'Reading and converting…',
        success: 'All done!',
        error: 'Something went wrong',
        cancelling: 'Cancelling…',
        cancelled: 'Cancelled',
      },
      jobLabel: (jobId: string) => `Request ID: ${jobId}`,
      placeholder: 'Upload a file to follow the step-by-step updates here.',
      errorPrefix: 'Details: {message}',
      toggleShow: 'Show terminal output',
      toggleHide: 'Hide terminal output',
      etaLabel: 'Estimated time',
      etaCalculating: 'calculating…',
      etaSoon: 'almost there',
      etaDone: 'finished',
      cancelButton: 'Stop conversion',
      cancelButtonPending: 'Cancelling…',
      progressLabel: 'Overall progress',
      summaryTitle: 'Run summary',
      summaryLanguage: 'Detected language',
      summaryChapters: 'Total chapters',
      summaryCurrent: 'Current chapter',
      summaryProgress: 'Progress',
    },
    downloads: {
      placeholder: 'When the conversion finishes, the audio files will show up here to play or download.',
      resetWithDownloads: 'Start another conversion',
      resetWithoutDownloads: 'Clear form',
      audioNotSupported: 'Your browser does not support audio playback.',
      downloadChapter: '⬇ Download MP3',
      downloadZip: 'Download Complete Audiobook (ZIP)',
      downloadZipHint: (count: number) => `Contains ${count} ${count === 1 ? 'chapter' : 'chapters'} in MP3`,
      orIndividual: 'Or download/listen to individual chapters',
    },
    layout: {
      footer: '',
    },
    flow: {
      start: 'Sending file to the server…',
      jobCreated: (jobId: string) => `Request ${jobId} received. Waiting for narration…`,
      resuming: '🔄 Resuming interrupted conversion…',
      completion: (count: number) => `Finished conversion with ${count} audio file(s).`,
      failure: (message: string) => `Request failed: ${message}`,
      error: (message: string) => `Error: ${message}`,
      defaultFailure: 'Conversion failed',
      defaultError: 'Unexpected error',
      cancelRequested: '🛑 Cancel request received. Finishing current step…',
      cancelled: 'Request cancelled by the user.',
      cancelFailed: (message: string) => `Unable to cancel: ${message || 'please try again'}`,
    },
  },
};

export function resolveLocale(input?: string | null): Locale {
  if (!input) return 'en';
  const normalised = input.toLowerCase();
  if (normalised.startsWith('pt')) return 'pt';
  return 'en';
}

export function getTranslations(locale: Locale): Translations {
  return translations[locale];
}
