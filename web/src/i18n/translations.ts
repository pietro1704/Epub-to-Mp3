import type { EngineOption, FootnoteMode, ChapterProgressStatus } from '../types/conversion';

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
  themeAuto: string;
  localeLabel: string;
  localeEnglish: string;
  localePortuguese: string;
  localeAuto: string;
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
    activeBadge?: string;
  };
  downloads: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
    footer: string;
  };
}

export interface ActiveConversionText {
  title: string;
  currentLabel: string;
  etaLabel: string;
  queueHint: string;
  description: string;
  viewProgress: string;
  cancel: string;
  engineLabel: string;
  voiceLabel: string;
  languageLabel: string;
}

export interface FormText {
  fileLabel: string;
  fileHint: string;
  fileQueueLabel: string;
  fileQueueEmpty: string;
  fileQueueWithCurrent: (title: string) => string;
  fileQueueCount: (count: number) => string;
  fileQueueRemove: string;
  fileQueueMoveUp: string;
  fileQueueMoveDown: string;
  fileQueueReorderHint: string;
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
  voiceLoading: string;
  voiceLoadFailed: string;
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
  autoUploadHint: string;
  autoUploadPending: string;
  autoUploadReady: string;
  uploadingFile: string;
  advancedSummary: string;
  errorFileTooLarge: (limitMb: number) => string;
  submitIdle: string;
  submitBusy: string;
  formattingCuesLabel: string;
  formattingCuesDescription: string;
  formattingCuesOn: string;
  formattingCuesOff: string;
}

export interface ProgressQueueText {
  title: string;
  subtitle: string;
  inputLabel: string;
  hint: string;
  success: (count: number) => string;
  errorFallback: string;
  phaseActive: string;
  phaseSuccess: string;
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
  summaryHint: string;
  summaryProgress: string;
  summaryParallel: string;
  chapterProgressTitle: string;
  chapterStatuses: Record<ChapterProgressStatus, string>;
  bookFallbackTitle: string;
  bookFallbackAuthor: string;
}

export interface ResumableJobsText {
  title: string;
  subtitle: string;
  empty: string;
  resumeButton: string;
  justNow: string;
  minutesAgo: (minutes: number) => string;
  hoursAgo: (hours: number) => string;
  daysAgo: (days: number) => string;
  engineLabel: (value: string) => string;
  voiceLabel: (value: string) => string;
  languageLabel: (value: string) => string;
}

export interface RecentJobsText {
  title: string;
  subtitle: string;
  resumeButton: string;
  downloadButton: string;
  viewAudiosButton: string;
  viewAudiosHint: string;
  empty: string;
  justNow: string;
  minutesAgo: (minutes: number) => string;
  hoursAgo: (hours: number) => string;
  daysAgo: (days: number) => string;
  stateLabels: Record<string, string>;
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
  downloadLog: string;
  viewLog: string;
  hideLog: string;
  logLoading: string;
  logError: (message: string) => string;
  viewingJobTitle: (title: string) => string;
  viewingJobSubtitle: string;
  viewingJobBackToCurrent: string;
  readyListTitle: string;
  readyListSubtitle: string;
  readyListAction: string;
  readyListItem: (count: number) => string;
  readyListAriaLabel: string;
  readyListTagCurrent: string;
  readyListTagPast: string;
  readyNotificationTitle: string;
  readyNotificationBody: (title: string) => string;
  readyNotificationBodyFallback: string;
}

export interface LayoutText {
  footer: string;
}

export interface FlowMessages {
  startUpload: string;
  startReuse: string;
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
  backendOffline: string;
  backendOfflineDetails: string;
  backendOfflineBanner: string;
  cancelConfirm: string;
  batchPosition: (index: number, total: number) => string;
  batchCancelled: (remaining: number) => string;
  notificationErrorTitle: string;
  notificationErrorBody: string;
  notificationCancelTitle: string;
  notificationCancelBody: string;
}

export interface Translations {
  locale: Locale;
  topBar: TopBarText;
  hero: HeroText;
  tabs: TabsText;
  activeConversion: ActiveConversionText;
  form: FormText;
  status: StatusText;
  resumableJobs: ResumableJobsText;
  recentJobs: RecentJobsText;
  downloads: DownloadsText;
  layout: LayoutText;
  flow: FlowMessages;
  queue: ProgressQueueText;
}

export const translations: Record<Locale, Translations> = {
  pt: {
    locale: 'pt',
    topBar: {
      ariaLabel: 'Preferências de tema e idioma',
      themeLabel: 'Tema',
      themeLight: 'Claro',
      themeDark: 'Escuro',
      themeAuto: 'Auto',
      localeLabel: 'Idioma',
      localeEnglish: 'Inglês',
      localePortuguese: 'Português',
      localeAuto: 'Auto',
    },
    resumableJobs: {
      title: 'Retomar conversões inacabadas',
      subtitle: 'Detectamos livros parcialmente convertidos. Clique para continuar de onde parou.',
      empty: 'Nenhuma conversão pendente para retomar.',
      resumeButton: 'Continuar agora',
      justNow: 'agora mesmo',
      minutesAgo: (m: number) => `há ${m} min`,
      hoursAgo: (h: number) => `há ${h}h`,
      daysAgo: (d: number) => `há ${d} dia${d > 1 ? 's' : ''}`,
      engineLabel: (value: string) => `Motor: ${value}`,
      voiceLabel: (value: string) => `Voz: ${value}`,
      languageLabel: (value: string) => `Idioma: ${value}`,
    },
    recentJobs: {
      title: '⚡ Conversões recentes',
      subtitle: 'Retome ou baixe rapidamente qualquer conversão salva no servidor.',
      resumeButton: 'Retomar',
      downloadButton: 'Baixar ZIP',
      viewAudiosButton: 'Ver áudios',
      viewAudiosHint: 'Abrir na aba 3 para ouvir capítulos individuais',
      empty: 'Nenhuma conversão finalizada disponível ainda.',
      justNow: 'agora mesmo',
      minutesAgo: (m: number) => `há ${m} min`,
      hoursAgo: (h: number) => `há ${h}h`,
      daysAgo: (d: number) => `há ${d} dia${d > 1 ? 's' : ''}`,
      stateLabels: {
        queued: 'Na fila',
        running: 'Convertendo',
        finished: 'Concluído',
        failed: 'Falhou',
        cancelling: 'Cancelando',
        cancelled: 'Cancelado',
        interrupted: 'Interrompido',
      },
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
        activeBadge: 'Convertendo agora',
      },
      downloads: {
        label: '3. Ouvir e baixar',
        description: 'Os capítulos prontos aparecem aqui para download imediato.',
        panelTitle: 'Seus arquivos MP3',
        panelDescription: 'Baixe os capítulos convertidos ou inicie outra conversão.',
        footer: '',
      },
    },
    activeConversion: {
      title: 'Conversão em andamento',
      currentLabel: 'Livro em processamento',
      etaLabel: 'Tempo estimado',
      queueHint: 'Qualquer novo arquivo enviado aqui entra na fila logo após este livro terminar.',
      description: 'Você pode continuar adicionando livros normalmente. Eles serão processados na sequência.',
      viewProgress: 'Ver andamento',
      cancel: 'Cancelar conversão',
      engineLabel: 'Motor',
      voiceLabel: 'Voz',
      languageLabel: 'Idioma',
    },
    form: {
      fileLabel: 'Arquivo do livro (EPUB ou PDF)',
      fileHint: 'Selecione um ou mais arquivos do seu computador. Todos usarão as mesmas configurações abaixo.',
      fileQueueLabel: 'Fila de livros',
      fileQueueEmpty: 'Nenhum livro na fila. Adicione quantos quiser antes de converter.',
      fileQueueWithCurrent: (title: string) => `“${title}” está sendo convertido. Novos livros entram logo depois.`,
      fileQueueCount: (count: number) => (count === 1 ? '1 livro' : `${count} livros`),
      fileQueueRemove: 'Remover',
      fileQueueMoveUp: 'Mover para cima',
      fileQueueMoveDown: 'Mover para baixo',
      fileQueueReorderHint: 'Arraste ou use as setas para alterar a ordem. Os livros serão convertidos de cima para baixo.',
      useSampleButton: 'Usar livro de exemplo',
      engineLabel: 'Como quer que a voz soe?',
      engineOptions: [
        {
          value: 'auto',
          label: 'Automático (padrão)',
          help: 'Escolhe Edge/Coqui/Piper por capítulo para máxima velocidade.',
        },
        {
          value: 'edge',
          label: 'Edge (nuvem Microsoft)',
          help: 'Vozes de nuvem da Microsoft. Ótima qualidade e sotaque natural.',
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
      voiceLoading: 'Carregando vozes recomendadas…',
      voiceLoadFailed: 'Não foi possível carregar a lista de vozes. Usando as sugestões padrão.',
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
      autoUploadHint: 'Detectamos título e capa automaticamente ao escolher o arquivo. Esse upload é reaproveitado na conversão.',
      autoUploadPending: 'Detectando capa e metadados…',
      autoUploadReady: 'Metadados detectados. Você já pode converter sem reenviar o arquivo.',
      uploadingFile: 'Enviando arquivo para detectar capa…',
      advancedSummary: 'Opções avançadas',
      errorFileTooLarge: (limit: number) => `Arquivo maior que ${limit} MB. Envie um EPUB/PDF menor para evitar falhas.`,
      submitIdle: 'Converter agora',
      submitBusy: 'Gerando áudio…',
      formattingCuesLabel: 'Narrar formatação (aspas, itálico, negrito)',
      formattingCuesDescription: 'Fala “entre aspas” e “fim das aspas”, “em negrito”, etc., usando o idioma do site.',
      formattingCuesOn: 'Ativado',
      formattingCuesOff: 'Desativado',
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
      summaryHint: 'Status em tempo real',
      summaryProgress: 'Progresso',
      summaryParallel: 'Capítulos em paralelo',
      chapterProgressTitle: 'Progresso por capítulo',
      chapterStatuses: {
        pending: 'Na fila',
        processing: 'Convertendo',
        completed: 'Concluído',
        skipped: 'Ignorado',
        failed: 'Falhou',
        cancelled: 'Cancelado',
      },
      bookFallbackTitle: 'Livro carregado',
      bookFallbackAuthor: 'Autor desconhecido',
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
      downloadLog: 'Baixar conversion.log',
      viewLog: 'Ver conversion.log',
      hideLog: 'Ocultar conversion.log',
      logLoading: 'Carregando conversion.log…',
      logError: (message: string) => `Não foi possível carregar conversion.log (${message}).`,
      viewingJobTitle: (title: string) => `Ouvindo capítulos de “${title}”`,
      viewingJobSubtitle: 'Esses arquivos vêm de uma conversão finalizada. Você pode voltar para os downloads atuais quando quiser.',
      viewingJobBackToCurrent: 'Ver downloads atuais',
      readyListTitle: 'Livros prontos para download',
      readyListSubtitle: 'Inclui títulos finalizados nesta fila e em sessões anteriores.',
      readyListAction: 'Abrir downloads',
      readyListItem: (count: number) => (count === 1 ? '1 capítulo pronto' : `${count} capítulos prontos`),
      readyListAriaLabel: 'Histórico de audiolivros disponíveis',
      readyListTagCurrent: 'Sessão atual',
      readyListTagPast: 'Sessões anteriores',
      readyNotificationTitle: 'Audiobook pronto',
      readyNotificationBody: (title: string) => `“${title}” acabou de terminar.`,
      readyNotificationBodyFallback: 'Um livro acabou de ser convertido.',
    },
    layout: {
      footer: '',
    },
    flow: {
      startUpload: 'Enviando arquivo para o servidor…',
      startReuse: 'Preparando conversão com o arquivo já enviado…',
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
      backendOffline: 'Servidor de conversão indisponível',
      backendOfflineDetails: 'Não foi possível contatar a API. Verifique se o backend Python está rodando (ex.: `python app.py` na porta 8000) ou configure VITE_API_BASE apontando para um servidor remoto.',
      backendOfflineBanner: 'Servidor Python não está respondendo. Inicie o backend local (`python app.py`) ou defina VITE_API_BASE apontando para seu backend remoto e recarregue esta página.',
      cancelConfirm: 'Parar agora interrompe a conversão atual, mas retomaremos das partes já concluídas. Deseja cancelar mesmo assim?',
      batchPosition: (index: number, total: number) => `📚 Livro ${index}/${total}`,
      batchCancelled: (remaining: number) => (remaining === 1
        ? 'Fila interrompida. 1 livro ainda não foi convertido.'
        : `Fila interrompida. ${remaining} livros ainda não foram convertidos.`),
      notificationErrorTitle: 'Conversão falhou',
      notificationErrorBody: 'Ocorreu um erro. Verifique o log para mais detalhes.',
      notificationCancelTitle: 'Conversão cancelada',
      notificationCancelBody: 'Você pode retomar esta conversão na seção de interrompidas.',
    },
    queue: {
      title: 'Adicionar livros enquanto converte',
      subtitle: 'Os arquivos abaixo usam as mesmas configurações do passo 1 e entram na fila assim que o livro atual terminar.',
      inputLabel: 'Escolha EPUB/PDF adicionais',
      hint: 'Você pode continuar acompanhando passo 2 enquanto novos livros aguardam automaticamente.',
      success: (count: number) => (count === 1 ? '1 livro adicionado à fila.' : `${count} livros adicionados à fila.`),
      errorFallback: 'Não foi possível adicionar à fila. Tente novamente.',
      phaseActive: 'Convertendo',
      phaseSuccess: 'Pronto para próxima fila',
    },
  },
  en: {
    locale: 'en',
    topBar: {
      ariaLabel: 'Theme and language preferences',
      themeLabel: 'Theme',
      themeLight: 'Light',
      themeDark: 'Dark',
      themeAuto: 'Auto',
      localeLabel: 'Language',
      localeEnglish: 'English',
      localePortuguese: 'Portuguese',
      localeAuto: 'Auto',
    },
    resumableJobs: {
      title: 'Resume pending conversions',
      subtitle: 'Pick up requests with cached chapters without uploading again.',
      empty: 'No conversions waiting to resume.',
      resumeButton: 'Resume now',
      justNow: 'just now',
      minutesAgo: (m: number) => `${m} min ago`,
      hoursAgo: (h: number) => `${h}h ago`,
      daysAgo: (d: number) => `${d} day${d > 1 ? 's' : ''} ago`,
      engineLabel: (value: string) => `Engine: ${value}`,
      voiceLabel: (value: string) => `Voice: ${value}`,
      languageLabel: (value: string) => `Language: ${value}`,
    },
    recentJobs: {
      title: '⚡ Recent conversions',
      subtitle: 'Pick up where you left off or download any finished job stored on the server.',
      resumeButton: 'Resume',
      downloadButton: 'Download ZIP',
      viewAudiosButton: 'Listen',
      viewAudiosHint: 'Jump to tab 3 and play individual chapters',
      empty: 'No finished conversions yet.',
      justNow: 'just now',
      minutesAgo: (m: number) => `${m} min ago`,
      hoursAgo: (h: number) => `${h}h ago`,
      daysAgo: (d: number) => `${d} day${d > 1 ? 's' : ''} ago`,
      stateLabels: {
        queued: 'Queued',
        running: 'Converting',
        finished: 'Finished',
        failed: 'Failed',
        cancelling: 'Cancelling',
        cancelled: 'Cancelled',
        interrupted: 'Interrupted',
      },
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
        activeBadge: 'Running',
      },
      downloads: {
        label: '3. Listen & download',
        description: 'Finished chapters become available for instant download.',
        panelTitle: 'Your MP3 files',
        panelDescription: 'Download the chapters or start another conversion.',
        footer: '',
      },
    },
    activeConversion: {
      title: 'Conversion in progress',
      currentLabel: 'Currently processing',
      etaLabel: 'Estimated time',
      queueHint: 'Any new upload here is queued right after this book is done.',
      description: 'Feel free to keep adding titles—everything waits in the queue.',
      viewProgress: 'View progress',
      cancel: 'Cancel conversion',
      engineLabel: 'Engine',
      voiceLabel: 'Voice',
      languageLabel: 'Language',
    },
    form: {
      fileLabel: 'Book file (EPUB or PDF)',
      fileHint: 'Select one or more files from your computer. Every book will reuse the same settings below.',
      fileQueueLabel: 'Queued books',
      fileQueueEmpty: 'No books queued yet. Add as many as you like before converting.',
      fileQueueWithCurrent: (title: string) => `"${title}" is converting now. New uploads will start right after.`,
      fileQueueCount: (count: number) => (count === 1 ? '1 book' : `${count} books`),
      fileQueueRemove: 'Remove',
      fileQueueMoveUp: 'Move up',
      fileQueueMoveDown: 'Move down',
      fileQueueReorderHint: 'Drag or use the arrows to reorder. Books convert from top to bottom.',
      useSampleButton: 'Use sample book',
      engineLabel: 'How should the voice sound?',
      engineOptions: [
        {
          value: 'auto',
          label: 'Auto (default)',
          help: 'Chooses Edge/Coqui/Piper per chapter for maximum speed.',
        },
        {
          value: 'edge',
          label: 'Edge (Microsoft cloud)',
          help: 'Microsoft cloud voices with natural accents.',
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
      voiceLoading: 'Loading recommended voices…',
      voiceLoadFailed: 'Unable to fetch the voice list. Using the built-in suggestions.',
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
      autoUploadHint: 'We extract title and cover automatically once you pick a file. That upload is reused during conversion.',
      autoUploadPending: 'Extracting cover and metadata…',
      autoUploadReady: 'Metadata detected. Conversion will reuse this upload.',
      uploadingFile: 'Uploading file to detect cover…',
      advancedSummary: 'Advanced options',
      errorFileTooLarge: (limit: number) => `File exceeds the ${limit} MB limit. Please upload a smaller EPUB/PDF.`,
      submitIdle: 'Convert now',
      submitBusy: 'Generating audio…',
      formattingCuesLabel: 'Narrate formatting (quotes, italics, bold)',
      formattingCuesDescription: 'Says “quote”, “end quote”, and other cues using the site language.',
      formattingCuesOn: 'Enabled',
      formattingCuesOff: 'Disabled',
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
      summaryHint: 'Realtime status',
      summaryProgress: 'Progress',
      summaryParallel: 'Parallel chapters',
      chapterProgressTitle: 'Chapter progress',
      chapterStatuses: {
        pending: 'Queued',
        processing: 'Converting',
        completed: 'Done',
        skipped: 'Skipped',
        failed: 'Failed',
        cancelled: 'Cancelled',
      },
      bookFallbackTitle: 'Uploaded book',
      bookFallbackAuthor: 'Unknown author',
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
      downloadLog: 'Download conversion.log',
      viewLog: 'View conversion.log',
      hideLog: 'Hide conversion.log',
      logLoading: 'Loading conversion.log…',
      logError: (message: string) => `Unable to load conversion.log (${message}).`,
      viewingJobTitle: (title: string) => `Listening to “${title}”`,
      viewingJobSubtitle: 'These files came from a finished conversion. Jump back anytime to see the current downloads.',
      viewingJobBackToCurrent: 'Back to current downloads',
      readyListTitle: 'Books ready to download',
      readyListSubtitle: 'Includes titles finished in this queue and earlier sessions.',
      readyListAction: 'Open downloads',
      readyListItem: (count: number) => (count === 1 ? '1 chapter ready' : `${count} chapters ready`),
      readyListAriaLabel: 'Available audiobooks',
      readyListTagCurrent: 'Current session',
      readyListTagPast: 'Past sessions',
      readyNotificationTitle: 'Audiobook ready',
      readyNotificationBody: (title: string) => `“${title}” just finished.`,
      readyNotificationBodyFallback: 'One of your books just finished converting.',
    },
    layout: {
      footer: '',
    },
    flow: {
      startUpload: 'Sending file to the server…',
      startReuse: 'Preparing conversion using the uploaded file…',
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
      backendOffline: 'Conversion server unavailable',
      backendOfflineDetails: 'Unable to reach the API. Make sure the Python backend is running (e.g., `python app.py` on port 8000) or configure VITE_API_BASE to point to a remote server.',
      backendOfflineBanner: 'Python backend is offline. Start it locally (`python app.py`) or set VITE_API_BASE to a reachable server, then reload this page.',
      cancelConfirm: 'Stopping now will abort the current conversion, but cached chapters remain. Do you really want to cancel?',
      batchPosition: (index: number, total: number) => `📚 Book ${index}/${total}`,
      batchCancelled: (remaining: number) => (remaining === 1
        ? 'Batch stopped. 1 book is still pending.'
        : `Batch stopped. ${remaining} books are still pending.`),
      notificationErrorTitle: 'Conversion failed',
      notificationErrorBody: 'Check the log for more details.',
      notificationCancelTitle: 'Conversion cancelled',
      notificationCancelBody: 'You can resume this conversion from the interrupted list.',
    },
    queue: {
      title: 'Queue more books',
      subtitle: 'Files you add here reuse the Step 1 settings and run right after the current book.',
      inputLabel: 'Select additional EPUB/PDF files',
      hint: 'Keep watching the progress while the next books wait in the background.',
      success: (count: number) => (count === 1 ? '1 book added to the queue.' : `${count} books added to the queue.`),
      errorFallback: 'Unable to add to the queue. Please try again.',
      phaseActive: 'In progress',
      phaseSuccess: 'Ready for next batch',
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
