import type { Translations } from './translation_contract';

export const pt_application: Pick<Translations, 'locale' | 'topBar' | 'hero' | 'tabs' | 'flow'> = {
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
  hero: {
    badge: 'Livro em áudio',
    title: 'Transforme seu EPUB ou PDF em MP3 com poucos cliques',
    subtitle:
      'Abra o livro e converta localmente com Piper. A voz instalada do sistema serve apenas para ouvir; exportar MP3 exige Piper.',
    highlights: [
      {
        title: 'Piper local',
        description:
          'Sua voz principal é preservada. Instale o modelo somente quando quiser habilitar a conversão offline.',
      },
      {
        title: 'Multi-idioma real',
        description:
          'Detectamos mudanças de idioma no texto e alternamos a voz sem precisar configurar nada.',
      },
      {
        title: 'Conversões retomáveis',
        description:
          'O cache inteligente retoma jobs interrompidos e evita refazer capítulos já prontos.',
      },
    ],
  },
  tabs: {
    setup: {
      label: '1. Preparar conversão',
      description: 'Envie o livro e escolha voz, notas e capítulos.',
      panelTitle: 'Envie seu livro',
      panelDescription: 'Faça o upload e escolha como o áudio deve soar.',
      savedBatchTitle: (count: number) =>
        `📋 Fila salva com ${count} livro${count !== 1 ? 's' : ''} pendente${count !== 1 ? 's' : ''}`,
      savedBatchResume: 'Retomar fila',
      savedBatchDismiss: 'Descartar',
      savedBatchNeedsReupload: (count: number) =>
        `⚠️ ${count} livro${count !== 1 ? 's precisam' : ' precisa'} ser reenviado${count !== 1 ? 's' : ''} (arquivo não pode ser salvo)`,
    },
    progress: {
      label: '2. Acompanhar andamento',
      description: 'Acompanhe a conversão local do livro neste dispositivo.',
      panelTitle: 'Status da conversão',
      panelDescription: 'Aqui ficam as mensagens mais recentes.',
      activeBadge: 'Convertendo agora',
      backButton: '← Voltar',
      viewDownloads: 'Ver Downloads →',
    },
    downloads: {
      label: '3. Ouvir e baixar',
      description: 'Os capítulos prontos aparecem aqui para download imediato.',
      panelTitle: 'Seus arquivos MP3',
      panelDescription: 'Baixe os capítulos convertidos ou inicie outra conversão.',
      footer: '',
      backButton: '← Voltar',
      followConversion: 'Acompanhar conversão →',
    },
  },
  flow: {
    startUpload: 'Enviando arquivo para o servidor…',
    startReuse: 'Preparando conversão com o arquivo já enviado…',
    jobCreated: (jobId: string) => `Pedido ${jobId} recebido. Aguardando narração…`,
    resuming: '🔄 Retomando conversão interrompida…',
    loadingCache: '📦 Recuperando dados desta conversão...',
    completion: (count: number) => `Conversão finalizada com ${count} arquivos de áudio.`,
    failure: (message: string) => `Pedido com erro: ${message}`,
    error: (message: string) => `Erro: ${message}`,
    defaultFailure: 'A conversão falhou',
    defaultError: 'Erro inesperado',
    cancelRequested: '🛑 Cancelamento solicitado. Concluindo passo atual…',
    cancelled: 'Pedido cancelado pelo usuário.',
    skipped: 'Livro atual ignorado, continuando com a fila.',
    cancelFailed: (message: string) => `Não foi possível cancelar: ${message || 'tente novamente'}`,
    skipConfirm: 'Deseja pular este livro e continuar com o próximo da fila?',
    backendOffline: 'Servidor de conversão indisponível',
    backendOfflineDetails:
      'Não foi possível contatar o runtime de conversão Rust. Verifique se o runtime local está disponível e recarregue a página.',
    backendConnecting: 'Conectando ao servidor de conversão…',
    backendOfflineBanner:
      'O runtime Rust de conversão não está respondendo. Verifique o runtime local e recarregue esta página.',
    cachedRestoredSuccess:
      'Restaurado do cache local. Os downloads podem estar indisponíveis se o servidor foi reiniciado.',
    cancelConfirm:
      'Cancelar agora interrompe a conversão atual e remove os arquivos gerados. Deseja continuar?',
    batchPosition: (index: number, total: number) => `📚 Livro ${index}/${total}`,
    batchCancelled: (remaining: number) =>
      remaining === 1
        ? 'Fila interrompida. 1 livro ainda não foi convertido.'
        : `Fila interrompida. ${remaining} livros ainda não foram convertidos.`,
    notificationErrorTitle: 'Conversão falhou',
    notificationErrorBody: 'Ocorreu um erro. Verifique o log para mais detalhes.',
    notificationCancelTitle: 'Conversão cancelada',
    notificationCancelBody:
      'Conversão cancelada e removida. Você pode iniciar uma nova conversão quando quiser.',
  },
};
