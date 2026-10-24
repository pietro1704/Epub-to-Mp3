import type { Translations } from "./translation_contract";

export const pt_conversion: Pick<
  Translations,
  "form" | "activeConversion" | "queue"
> = {
  activeConversion: {
    title: "Conversão em andamento",
    currentLabel: "Livro em processamento",
    etaLabel: "Tempo estimado",
    queueHint:
      "Qualquer novo arquivo enviado aqui entra na fila logo após este livro terminar.",
    description:
      "Você pode continuar adicionando livros normalmente. Eles serão processados na sequência.",
    viewProgress: "Ver andamento",
    cancel: "Cancelar conversão",
    skip: "Pular para próximo",
    engineLabel: "Motor",
    voiceLabel: "Voz",
    languageLabel: "Idioma",
  },
  form: {
    ttsPreferences: {
      primary: "Voz principal",
      secondary: "Voz secundária",
      none: "Nenhuma",
      online: "Permitir reserva online",
      inherit: "Usar preferências",
      reserve: "Permitir secundário nesta conversão",
      install: "Instalar modelo selecionado",
      installed: "Modelo selecionado instalado",
      installing: "Instalando…",
      system: "TTS do sistema — só para ouvir; MP3 exige Piper",
      nativeNotice:
        "Piper indisponível. A voz do sistema serve apenas para ouvir; exportar MP3 exige Piper.",
      nativeListen: "Ouvir com voz instalada do sistema",
      nativePause: "Pausar",
      nativeResume: "Continuar",
      nativeStop: "Parar",
      nativeRetry: "Tentar conversão com Piper novamente",
      nativeUnavailable:
        "A voz do sistema não está disponível neste navegador.",
      capability:
        "Modelos Piper compatíveis funcionam localmente após a instalação. Edge não está disponível neste navegador.",
      unavailable: "indisponível neste navegador",
      manualVoice: "Voz desta conversão",
    },
    fileLabel: "Arquivo do livro (EPUB ou PDF)",
    fileHint:
      "Selecione um ou mais arquivos do seu computador. Todos usarão as mesmas configurações abaixo.",
    fileQueueLabel: "Fila de livros",
    fileQueueEmpty:
      "Nenhum livro na fila. Adicione quantos quiser antes de converter.",
    fileQueueWithCurrent: (title: string) =>
      `“${title}” está sendo convertido. Novos livros entram logo depois.`,
    fileQueueCount: (count: number) =>
      count === 1 ? "1 livro" : `${count} livros`,
    fileQueueRemove: "Remover",
    fileQueueMoveUp: "Mover para cima",
    fileQueueMoveDown: "Mover para baixo",
    fileQueueReorderHint:
      "Arraste ou use as setas para alterar a ordem. Os livros serão convertidos de cima para baixo.",
    useSampleButton: "Usar livro de exemplo",
    addFolderButton: "Adicionar pasta inteira",
    engineLabel: "Como quer que a voz soe?",
    engineOptions: [
      {
        value: "edge",
        label: "Edge (padrão)",
        help: "Vozes de nuvem da Microsoft. Mais rápido (~70 chars/s). Multilíngue.",
      },
      {
        value: "piper",
        label: "Piper",
        help: "Modelos PT/EN incluídos. Offline, qualidade básica.",
      },
    ],
    engineDetails: {
      edge: {
        tagline:
          "A escolha mais versátil — vozes neurais na nuvem da Microsoft",
        quality: "Alta — entonação natural, respiração realista",
        speed: "~70 chars/s — o mais rápido de todos",
        requirements: "Conexão com a internet",
        bestVoice: "pt-BR-ThalitaMultilingualNeural",
        bestVoiceNote:
          "Thalita é multilíngue: troca de idioma automaticamente no mesmo texto. Para voz masculina, use AntonioNeural.",
        pros: [
          "Mais rápido de todos os motores",
          "Vozes naturais com entonação expressiva",
          "16+ vozes em pt-BR (femininas e masculinas)",
          "Multilíngue automático com Thalita",
          "Não precisa baixar nada",
        ],
        cons: [
          "Precisa de internet",
          "Pode sofrer rate-limiting em uso intenso",
          "Vozes são da Microsoft (não 100% open-source)",
        ],
        languages: "Todos (automático) — pt, en, es, fr, de, it, ja, zh e mais",
      },
      piper: {
        tagline: "Leve e offline — opção local instalada pelo usuário",
        quality: "Básica — voz robótica mas inteligível",
        speed: "~25 chars/s — moderado",
        requirements: "Runtime Piper e modelo compatível instalados",
        bestVoice: "pt_BR-faber-medium.onnx",
        bestVoiceNote:
          "Faber é a melhor voz pt-BR disponível. Para inglês, Lessac-medium tem qualidade superior.",
        pros: [
          "100% offline — sem internet necessária",
          "Extremamente leve (~15 MB por modelo)",
          "Funciona em qualquer hardware",
          "Pode funcionar sem internet após a instalação explícita",
        ],
        cons: [
          "Qualidade de voz mais robótica",
          "Poucos modelos em português",
          "Sem expressividade emocional",
          "Um modelo por idioma (não multilíngue)",
        ],
        languages: "pt-BR, en-US, es, fr, de, it (um modelo por idioma)",
      },
    },
    autoEngineComparisonTitle: "Comparação rápida dos motores",
    autoEngineComparisonNote:
      "No modo automático, o sistema escolhe o melhor motor disponível com base no idioma e nos recursos da máquina.",
    comparisonHeaders: {
      engine: "Motor",
      quality: "Qualidade",
      speed: "Velocidade",
      languages: "Idiomas",
      needs: "Requisitos",
    },
    voicePreviewPlay: "Ouvir amostra",
    voicePreviewStop: "Parar",
    voicePreviewLoading: "Gerando amostra…",
    voicePreviewError: "Falha ao gerar amostra. Tente outra voz.",
    defaultVoiceLabel: "Voz padrão com suporte a vários idiomas",
    multilingualSupportLabel: "Suporte multilíngue",
    multilingualYes: "Sim, detecta automaticamente.",
    multilingualNo: "Não, escolha o idioma manualmente.",
    autoLanguageLabel: "Detecção automática de idioma ativada.",
    manualLanguageLabel: "Selecione o idioma para esta conversão.",
    voiceLabel: "Nome da voz (opcional)",
    voicePlaceholder: "Deixe vazio para usar a voz padrão",
    voiceHint:
      "Você pode escolher uma voz específica se souber o nome dela. Caso contrário, mantenha em branco.",
    voiceMultilingualHint:
      "Esta voz suporta múltiplos idiomas automaticamente.",
    voiceLoading: "Carregando vozes recomendadas…",
    voiceLoadFailed:
      "Não foi possível carregar a lista de vozes. Usando as sugestões padrão.",
    chaptersLabel: "Quais capítulos você quer ouvir? (opcional)",
    chaptersPlaceholder: "Ex.: 1,2 ou 3.1 (deixe em branco para todos)",
    chaptersHint:
      "Separe os números por vírgula. O app usa todos os capítulos se você deixar vazio.",
    fromChapterToEndLabel:
      "Converter do capítulo (inclusive) até o fim (opcional)",
    fromChapterToEndPlaceholder: "Ex.: 5.1",
    fromChapterToEndHint:
      "Use a mesma sintaxe do campo de capítulos. Deixe vazio para ignorar.",
    fromChapterToChapterLabel: "Converter intervalo de capítulos (opcional)",
    fromChapterToChapterPlaceholder: "Ex.: 5.1..7.3",
    fromChapterToChapterHint:
      "Informe início e fim com '..' (mesma sintaxe do campo de capítulos).",
    priorityLabel: "Quais capítulos devem ter prioridade? (opcional)",
    priorityPlaceholder: "Ex.: 1,4 ou Prólogo (sintaxe igual ao campo acima)",
    priorityHint:
      "Capítulos listados aqui são narrados primeiro, depois o restante segue na ordem original.",
    footnoteLegend: "Como tratar as notas de rodapé?",
    footnoteOptions: [
      {
        value: "inline",
        title: "Ler junto com a história",
        description:
          "As notas entram na mesma hora do texto. Ideal para quem não quer perder detalhes.",
      },
      {
        value: "chapter_end",
        title: "Ler depois do capítulo",
        description:
          "Guarda as notas para o final de cada capítulo. O áudio principal fica mais limpo.",
      },
      {
        value: "skip",
        title: "Não ler as notas",
        description:
          "Ignora notas de rodapé por completo. Use se elas não forem importantes para você.",
      },
    ],
    languageLabel: "Idioma do áudio",
    languagePlaceholder: "Selecione o idioma principal",
    languageHint:
      "Escolha o idioma quando o motor não fizer detecção automática.",
    languageNotRequired: "Este motor detecta o idioma sozinho.",
    languageAutoDetected:
      "O idioma será detectado automaticamente a partir do livro.",
    voiceAutoSelected:
      "A voz será selecionada automaticamente com base no idioma detectado.",
    voiceAutoOption: "Seleção automática por idioma",
    languageOptions: {
      auto: "Automático",
      pt: "Português (Brasil)",
      en: "Inglês (Estados Unidos)",
      es: "Espanhol (América Latina)",
      fr: "Francês",
      de: "Alemão",
    },
    availableLanguagesLabel: "Idiomas disponíveis",
    errorNoFile: "Selecione um arquivo EPUB ou PDF antes de enviar.",
    autoUploadHint:
      "Detectamos título e capa automaticamente ao escolher o arquivo. Esse upload é reaproveitado na conversão.",
    autoUploadPending: "Detectando capa e metadados…",
    autoUploadReady:
      "Metadados detectados. Você já pode converter sem reenviar o arquivo.",
    uploadingFile: "Enviando arquivo para detectar capa…",
    advancedSummary: "Opções avançadas",
    errorFileTooLarge: (limit: number) =>
      `Arquivo maior que ${limit} MB. Envie um EPUB/PDF menor para evitar falhas.`,
    submitIdle: "Converter agora",
    submitBusy: "Converter agora",
    estimatedDuration: (f: string) => `~${f}`,
    formattingCuesLabel: "Narrar formatação (aspas, itálico, negrito)",
    formattingCuesDescription:
      "Fala “entre aspas” e “fim das aspas”, “em negrito”, etc., usando o idioma do site.",
    formattingCuesOn: "Ativado",
    formattingCuesOff: "Desativado",
    characterVoicesLabel: "Vozes diferentes para narrador e personagens",
    characterVoicesDescription:
      "Trechos entre aspas ou em linhas começando com travessão são lidos com a voz dos personagens; o resto fica com a voz do narrador.",
    characterVoicesOn: "Ativado",
    characterVoicesOff: "Desativado",
    narratorVoiceLabel: "Voz do narrador",
    characterVoiceLabel: "Voz dos personagens",
    characterVoicesAutoOption: "Mesma voz selecionada acima",
    exportToIphoneLabel: "Enviar para iPhone (iCloud Drive)",
    exportToIphoneDescription:
      "Ao terminar, copia os MP3 para a pasta MP3AudioBookPlayer no iCloud Drive. Sincroniza automaticamente para o iPhone, sem cabo. macOS apenas.",
    exportToIphoneOn: "Ativado",
    exportToIphoneOff: "Desativado",
    noParallelLabel: "Desativar paralelismo (1 capítulo por vez)",
    noParallelDescription:
      "Útil para Edge online em redes instáveis; reduz travamentos e pode ser mais rápido.",
    noParallelOn: "Sequencial",
    noParallelOff: "Automático",
    multiEngineParallelLabel: "Múltiplos engines em paralelo",
    multiEngineParallelDescription:
      "Usa Edge e Piper simultaneamente em capítulos diferentes para máxima velocidade. Desligado por padrão — engines locais podem ter erros de detecção de idioma.",
    multiEngineParallelOn: "Ativado",
    multiEngineParallelOff: "Desativado",
    maxPerformanceLabel: "Velocidade máxima",
    maxPerformanceDescription:
      "Tenta usar o maior paralelismo e chunks mais longos (pode exigir mais CPU/RAM).",
    maxPerformanceOn: "Turbo ligado",
    maxPerformanceOff: "Balanceado",
    parallelSlotsLabel: "Capítulos em paralelo (opcional)",
    parallelSlotsPlaceholder: "Deixe vazio para automático",
    parallelSlotsHint:
      "Define quantos capítulos podem ser processados ao mesmo tempo.",
    chapterStallSecondsLabel: "Watchdog: travamento por capítulo (s)",
    chapterStallSecondsPlaceholder: "Ex.: 60",
    chapterStallSecondsHint:
      "Reinicia o capítulo se ficar sem progresso por esse tempo.",
    edgeNetworkTierLabel: "Edge: perfil de rede",
    edgeNetworkTierHint:
      "Força um perfil de rede para ajustar o Edge logo no início.",
    edgeNetworkTierAuto: "Auto",
    edgeNetworkTierSlow: "Lenta",
    edgeNetworkTierMedium: "Média",
    edgeNetworkTierFast: "Rápida",
    edgeNetworkTierUltra: "Ultra",
    engineTuningLegend: "Ajustes por engine",
    modelLabel: "Modelo (Piper) opcional",
    modelPlaceholder: "Ex.: tts_models/multilingual/multi-dataset/xtts_v2",
    modelHint:
      "Informe o ID do modelo ou caminho local no servidor (se aplicável).",
    edgeChunkCharsLabel: "Edge: tamanho do chunk (chars)",
    edgeChunkCharsPlaceholder: "Ex.: 24000",
    edgeChunkCharsHint:
      "Chunks maiores tendem a acelerar, mas podem falhar em redes instáveis.",
    edgeMaxSegmentSecondsLabel: "Edge: limite por segmento (s)",
    edgeMaxSegmentSecondsPlaceholder: "Ex.: 95",
    edgeMaxSegmentSecondsHint:
      "Limite de duração por segmento antes de dividir o texto.",
    edgeEnableParallelLabel: "Edge: paralelismo interno",
    edgeEnableParallelHint:
      "Ativa o processamento paralelo de segmentos dentro do capítulo.",
    edgeEnableParallelOn: "Ativado",
    edgeEnableParallelOff: "Desativado",
    edgeAutoTuneLabel: "Edge: auto-ajuste",
    edgeAutoTuneHint:
      "Ajusta chunk/tempo conforme rede e performance detectadas.",
    edgeAutoTuneOn: "Ativado",
    edgeAutoTuneOff: "Desativado",
    edgeStableModeLabel: "Edge: modo estável",
    edgeStableModeHint:
      "Força menos paralelismo e timeouts maiores para reduzir falhas em capítulos longos.",
    edgeStableModeOn: "Estável",
    edgeStableModeOff: "Normal",
    engineChainFallbackLabel: "Cascata de engines (legado)",
    engineChainFallbackHint:
      "Por padrão, permanecemos no Edge; falhas isoladas usam fallback por chunk. Ative para reabrir a cascata Edge → Piper quando o Edge estiver rate-limitado.",
    engineChainFallbackOn: "Cascata ativa",
    engineChainFallbackOff: "Só Edge",
    piperMaxProcsLabel: "Piper: processos simultâneos",
    piperMaxProcsPlaceholder: "Ex.: 3",
    piperMaxProcsHint: "Define o limite de processos Piper em paralelo.",
    audioLegend: "Saída de áudio",
    bitrateLabel: "Bitrate (kbps)",
    bitratePlaceholder: "Ex.: 8k",
    bitrateHint: "Valores menores geram arquivos menores (voz ainda fica ok).",
    sampleRateLabel: "Sample rate (Hz)",
    sampleRatePlaceholder: "Ex.: 16000",
    sampleRateHint:
      "16kHz é suficiente para voz; valores maiores aumentam tamanho.",
    channelsLabel: "Canais",
    channelsHint: "Mono é recomendado para audiobooks.",
    channelsMono: "Mono (1)",
    channelsStereo: "Estéreo (2)",
    processingLegend: "Processamento",
    verboseLabel: "Logs detalhados",
    verboseDescription: "Exibe saída detalhada das engines no painel.",
    verboseOn: "Ativado",
    verboseOff: "Reduzido",
    clearCacheLabel: "Limpar cache antes de converter",
    clearCacheDescription:
      "Remove textos/trechos em cache deste livro antes de iniciar.",
    clearCacheOn: "Limpar",
    clearCacheOff: "Manter",
    forceReprocessLabel: "Forçar reprocessamento",
    forceReprocessDescription: "Ignora arquivos já gerados e refaz tudo.",
    forceReprocessOn: "Forçar",
    forceReprocessOff: "Normal",
    filterChaptersLabel: "Filtrar capítulos curtos",
    filterChaptersDescription:
      "Remove trechos muito pequenos ao montar o índice.",
    filterChaptersOn: "Filtrar",
    filterChaptersOff: "Manter",
    languageDetectionLegend: "Detecção de idioma",
    languageDetectionLabel: "Detectar idioma no texto",
    languageDetectionDescription:
      "Marca trechos em outros idiomas automaticamente.",
    languageDetectionOn: "Ativado",
    languageDetectionOff: "Desativado",
    prioritizePrimaryLanguageLabel: "Priorizar idioma principal",
    prioritizePrimaryLanguageDescription:
      "Em ambiguidades, mantém o idioma principal do livro.",
    prioritizePrimaryLanguageOn: "Ativado",
    prioritizePrimaryLanguageOff: "Desativado",
    healthCheckLegend: "Healthcheck automático",
    healthCheckIntervalLabel: "Intervalo do healthcheck (s)",
    healthCheckIntervalPlaceholder: "Auto (30)",
    healthCheckIntervalHint:
      "Verifica lentidão/uso de recursos e ajusta o paralelismo.",
    healthCheckSlowEdgeCpsLabel: "Limiar Edge (chars/s)",
    healthCheckSlowEdgeCpsPlaceholder: "Auto (EDGE_MIN)",
    healthCheckSlowEdgeCpsHint: "Abaixo disso, ativa modo seguro do Edge.",
    healthCheckSlowCpsLabel: "Limiar outros motores (chars/s)",
    healthCheckSlowCpsPlaceholder: "Auto (30)",
    healthCheckSlowCpsHint: "Abaixo disso, reduz paralelismo para estabilizar.",
    healthCheckHighCpuLabel: "CPU alta (%)",
    healthCheckHighCpuPlaceholder: "Auto (85)",
    healthCheckHighCpuHint: "Acima disso, reduz paralelismo.",
    healthCheckHighMemLabel: "Memória alta (%)",
    healthCheckHighMemPlaceholder: "Auto (85)",
    healthCheckHighMemHint: "Acima disso, reduz paralelismo.",
    healthCheckOkCpuLabel: "CPU ok (%)",
    healthCheckOkCpuPlaceholder: "Auto (75)",
    healthCheckOkCpuHint: "Abaixo disso, pode aumentar paralelismo.",
    healthCheckOkMemLabel: "Memória ok (%)",
    healthCheckOkMemPlaceholder: "Auto (80)",
    healthCheckOkMemHint: "Abaixo disso, pode aumentar paralelismo.",
    healthCheckSlowStreakLabel: "Lentidão consecutiva",
    healthCheckSlowStreakPlaceholder: "Auto (2)",
    healthCheckSlowStreakHint: "Quantidade de checks lentos antes de ajustar.",
    sectionsLabel: "Seções adicionais (opcional)",
    sectionsPlaceholder: "Ex.: 2.1, 2.2 ou epílogo",
    sectionsHint:
      "Use para selecionar subseções ou títulos específicos junto ao campo acima.",
  },
  queue: {
    title: "Adicionar livros enquanto converte",
    subtitle:
      "Os arquivos abaixo usam as mesmas configurações do passo 1 e entram na fila assim que o livro atual terminar.",
    inputLabel: "Escolha EPUB/PDF adicionais",
    hint: "Você pode continuar acompanhando passo 2 enquanto novos livros aguardam automaticamente.",
    addFolderButton: "Escolher pasta",
    success: (count: number) =>
      count === 1
        ? "1 livro adicionado à fila."
        : `${count} livros adicionados à fila.`,
    errorFallback: "Não foi possível adicionar à fila. Tente novamente.",
    phaseActive: "Convertendo",
    phaseSuccess: "Pronto para próxima fila",
    displayCurrentLabel: "Convertendo agora",
    displayQueueLabel: (count: number) =>
      `Na fila: ${count} ${count === 1 ? "livro" : "livros"}`,
    displayMoreLabel: (count: number) =>
      `+ ${count} ${count === 1 ? "outro" : "outros"}`,
    displayResumeButton: "▶ Retomar fila",
    displayClearButton: "Limpar fila",
    displayPausedBadge: "Pausada",
    displayShowLess: "Mostrar menos",
    displayMoveUp: "Mover para cima",
    displayMoveDown: "Mover para baixo",
  },
};
