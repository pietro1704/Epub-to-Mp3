import { API_BASE_URL, POLL_INTERVAL_MS } from '../config';
import {
  ConversionFormValues,
  JobSnapshot,
} from '../types/conversion';

export interface PollOptions {
  intervalMs?: number;
  signal?: AbortSignal;
  onSnapshot?: (snapshot: JobSnapshot) => void;
}

export interface ConversionClient {
  submit(request: ConversionFormValues): Promise<{ jobId: string }>;
  fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot>;
  poll(jobId: string, options?: PollOptions): Promise<JobSnapshot>;
}

function buildFormData(values: ConversionFormValues): FormData {
  const formData = new FormData();
  formData.append('file', values.file);
  formData.append('engine', values.engine);
  if (values.voice) {
    formData.append('voice', values.voice);
  }
  if (values.chapters) {
    formData.append('chapters', values.chapters);
  }
  if (values.footnoteMode) {
    formData.append('footnote_mode', values.footnoteMode);
  }
  if (values.language) {
    formData.append('language', values.language);
  }
  return formData;
}

async function parseResponse<T>(response: Response): Promise<T> {
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Backend responded with status ${response.status}`);
  }
  return response.json() as Promise<T>;
}

export function normalizeAssetUrl(baseUrl: string, assetUrl: string): string {
  if (!assetUrl) {
    return assetUrl;
  }
  if (/^https?:\/\//i.test(assetUrl)) {
    return assetUrl;
  }

  const origin = typeof window !== 'undefined' && window.location ? window.location.origin : '';
  const trimmedBase = (baseUrl || '').trim();

  if (trimmedBase && /^https?:\/\//i.test(trimmedBase)) {
    try {
      return new URL(assetUrl, trimmedBase).toString();
    } catch (_error) {
      return assetUrl;
    }
  }

  if (assetUrl.startsWith('/')) {
    return origin ? `${origin}${assetUrl}` : assetUrl;
  }

  if (trimmedBase) {
    const prefix = trimmedBase.startsWith('/')
      ? `${origin}${trimmedBase}`
      : origin
        ? `${origin}/${trimmedBase}`
        : trimmedBase;
    return `${prefix.replace(/\/$/, '')}/${assetUrl.replace(/^\//, '')}`;
  }

  return origin ? `${origin}/${assetUrl.replace(/^\//, '')}` : assetUrl;
}

async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    throw new DOMException('Aborted', 'AbortError');
  }

  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      if (signal) {
        signal.removeEventListener('abort', onAbort);
      }
      resolve();
    }, ms);

    const onAbort = () => {
      clearTimeout(timeout);
      reject(new DOMException('Aborted', 'AbortError'));
    };

    if (signal) {
      signal.addEventListener('abort', onAbort, { once: true });
    }
  });
}

export class HttpConversionClient implements ConversionClient {
  constructor(private readonly baseUrl: string = API_BASE_URL) {}

  private resolve(path: string): string {
    const normalizedBase = this.baseUrl.replace(/\/$/, '');
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    return `${normalizedBase}${normalizedPath}`;
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    const response = await fetch(this.resolve('/api/convert'), {
      method: 'POST',
      body: buildFormData(request),
    });
    return parseResponse<{ jobId: string }>(response);
  }

  async fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot> {
    const response = await fetch(this.resolve(`/api/jobs/${encodeURIComponent(jobId)}`), {
      method: 'GET',
      signal,
    });
    if (response.status === 404) {
      return {
        jobId,
        state: 'queued',
        events: [],
      } satisfies JobSnapshot;
    }
    const snapshot = await parseResponse<JobSnapshot>(response);
    if (Array.isArray(snapshot.outputs)) {
      snapshot.outputs = snapshot.outputs.map((asset) => ({
        ...asset,
        url: normalizeAssetUrl(this.baseUrl, asset.url),
      }));
    }
    return snapshot;
  }

  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    const interval = options.intervalMs ?? POLL_INTERVAL_MS;
    const { signal } = options;

    while (true) {
      const snapshot = await this.fetch(jobId, signal);
      options.onSnapshot?.(snapshot);

      if (snapshot.state === 'finished' || snapshot.state === 'failed') {
        return snapshot;
      }

      await sleep(interval, signal);
    }
  }
}

export class MockConversionClient implements ConversionClient {
  private jobCounter = 0;

  private createMockAudio(chapterName: string, durationSeconds: number): string {
    // Create a simple audio context to generate a beep tone
    const audioContext = new (window.AudioContext || (window as any).webkitAudioContext)();
    const sampleRate = audioContext.sampleRate;
    const duration = durationSeconds;
    const numSamples = sampleRate * duration;
    const audioBuffer = audioContext.createBuffer(1, numSamples, sampleRate);
    const channelData = audioBuffer.getChannelData(0);

    // Generate a simple sine wave beep at 440Hz (A note)
    const frequency = 440;
    for (let i = 0; i < numSamples; i++) {
      const t = i / sampleRate;
      // Fade in/out envelope to avoid clicks
      const envelope = Math.min(t * 10, (duration - t) * 10, 1);
      channelData[i] = Math.sin(2 * Math.PI * frequency * t) * 0.3 * envelope;
    }

    // Convert to WAV format
    const wav = this.audioBufferToWav(audioBuffer);
    const blob = new Blob([wav], { type: 'audio/wav' });
    return URL.createObjectURL(blob);
  }

  private audioBufferToWav(buffer: AudioBuffer): ArrayBuffer {
    const numChannels = buffer.numberOfChannels;
    const sampleRate = buffer.sampleRate;
    const format = 1; // PCM
    const bitDepth = 16;

    const bytesPerSample = bitDepth / 8;
    const blockAlign = numChannels * bytesPerSample;

    const data = this.interleave(buffer);
    const dataLength = data.length * bytesPerSample;
    const headerLength = 44;
    const totalLength = headerLength + dataLength;

    const arrayBuffer = new ArrayBuffer(totalLength);
    const view = new DataView(arrayBuffer);

    // Write WAV header
    this.writeString(view, 0, 'RIFF');
    view.setUint32(4, totalLength - 8, true);
    this.writeString(view, 8, 'WAVE');
    this.writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true); // fmt chunk size
    view.setUint16(20, format, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * blockAlign, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, bitDepth, true);
    this.writeString(view, 36, 'data');
    view.setUint32(40, dataLength, true);

    // Write audio data
    this.floatTo16BitPCM(view, 44, data);

    return arrayBuffer;
  }

  private interleave(buffer: AudioBuffer): Float32Array {
    const numChannels = buffer.numberOfChannels;
    const length = buffer.length * numChannels;
    const result = new Float32Array(length);

    for (let channel = 0; channel < numChannels; channel++) {
      const channelData = buffer.getChannelData(channel);
      for (let i = 0; i < buffer.length; i++) {
        result[i * numChannels + channel] = channelData[i];
      }
    }

    return result;
  }

  private writeString(view: DataView, offset: number, str: string): void {
    for (let i = 0; i < str.length; i++) {
      view.setUint8(offset + i, str.charCodeAt(i));
    }
  }

  private floatTo16BitPCM(view: DataView, offset: number, input: Float32Array): void {
    for (let i = 0; i < input.length; i++, offset += 2) {
      const s = Math.max(-1, Math.min(1, input[i]));
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    this.jobCounter++;
    const jobId = `mock-job-${this.jobCounter}`;
    console.log('[MockClient] Conversion started:', { jobId, request });
    return { jobId };
  }

  async fetch(jobId: string): Promise<JobSnapshot> {
    return {
      jobId,
      state: 'queued',
      events: ['Mock: Job received', 'Mock: Processing started'],
    };
  }

  private createMockZip(bookTitle: string): string {
    // Create a simple ZIP-like file with mock content
    const content = `Mock Audiobook ZIP: ${bookTitle}

This ZIP file would contain:
- 001 - Capítulo 1.mp3
- 002 - Capítulo 2.mp3
- 003 - Capítulo 3.mp3

Generated: ${new Date().toISOString()}
Note: In production, this would be a real ZIP with all MP3 files.
`;
    const blob = new Blob([content], { type: 'application/zip' });
    return URL.createObjectURL(blob);
  }

  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    const bookTitle = 'Livro_de_Exemplo';

    // Create individual chapter MP3s with different durations
    const chapter1 = this.createMockAudio('001 - Capítulo 1', 3);
    const chapter2 = this.createMockAudio('002 - Capítulo 2', 4);
    const chapter3 = this.createMockAudio('003 - Capítulo 3', 5);
    const zipUrl = this.createMockZip(bookTitle);

    const steps: JobSnapshot[] = [
      {
        jobId,
        state: 'running',
        events: [
          '📚 METADADOS DO EBOOK',
          '================================================================',
          '📜 Título: Livro de Exemplo',
          '✍️ Autor: Autor Desconhecido',
          '📊 Capítulos: 3',
          '📝 Total de caracteres: 12,450',
        ],
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 5,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 METADADOS DO EBOOK',
          '================================================================',
          '📜 Título: Livro de Exemplo',
          '✍️ Autor: Autor Desconhecido',
          '📊 Capítulos: 3',
          '📝 Total de caracteres: 12,450',
          '',
          '🌐 DETECÇÃO DE IDIOMA',
          '----------------------------------------------------------------',
          '🌐 Idioma principal: pt-BR (confiança: Alta)',
          '   Probabilidade: 95.2%',
          '🔍 Caracteres analisados: 12,450',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 15,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 METADADOS DO EBOOK',
          '================================================================',
          '📜 Título: Livro de Exemplo',
          '✍️ Autor: Autor Desconhecido',
          '📊 Capítulos: 3',
          '📝 Total de caracteres: 12,450',
          '',
          '🌐 DETECÇÃO DE IDIOMA',
          '----------------------------------------------------------------',
          '🌐 Idioma principal: pt-BR (confiança: Alta)',
          '   Probabilidade: 95.2%',
          '🔍 Caracteres analisados: 12,450',
          '',
          '🎯 Convertendo capítulo 1/3: Capítulo 1',
          'Processando: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 45s',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 1,
        currentChapter: 'Capítulo 1',
        progressPercent: 33,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 METADADOS DO EBOOK',
          '================================================================',
          '📜 Título: Livro de Exemplo',
          '✍️ Autor: Autor Desconhecido',
          '📊 Capítulos: 3',
          '📝 Total de caracteres: 12,450',
          '',
          '🌐 DETECÇÃO DE IDIOMA',
          '----------------------------------------------------------------',
          '🌐 Idioma principal: pt-BR (confiança: Alta)',
          '   Probabilidade: 95.2%',
          '🔍 Caracteres analisados: 12,450',
          '',
          '🎯 Convertendo capítulo 1/3: Capítulo 1',
          'Processando: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 45s',
          '✅ Concluído: 001 - Capítulo 1.mp3',
          '',
          '🎯 Convertendo capítulo 2/3: Capítulo 2',
          'Processando: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 22s',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 2,
        currentChapter: 'Capítulo 2',
        progressPercent: 67,
      },
      {
        jobId,
        state: 'finished',
        events: [
          '📚 METADADOS DO EBOOK',
          '================================================================',
          '📜 Título: Livro de Exemplo',
          '✍️ Autor: Autor Desconhecido',
          '📊 Capítulos: 3',
          '📝 Total de caracteres: 12,450',
          '',
          '🌐 DETECÇÃO DE IDIOMA',
          '----------------------------------------------------------------',
          '🌐 Idioma principal: pt-BR (confiança: Alta)',
          '   Probabilidade: 95.2%',
          '🔍 Caracteres analisados: 12,450',
          '',
          '🎯 Convertendo capítulo 1/3: Capítulo 1',
          'Processando: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 45s',
          '✅ Concluído: 001 - Capítulo 1.mp3',
          '',
          '🎯 Convertendo capítulo 2/3: Capítulo 2',
          'Processando: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 22s',
          '✅ Concluído: 002 - Capítulo 2.mp3',
          '',
          '🎯 Convertendo capítulo 3/3: Capítulo 3',
          'Processando: [██████████████████████████████] 100.0% (3/3) ETA: 0s',
          '✅ Concluído: 003 - Capítulo 3.mp3',
          '',
          '📦 Criando arquivo ZIP: Livro_de_Exemplo.zip',
          '✅ Conversão finalizada em 1m 8s',
          '📁 Arquivo disponível: Livro_de_Exemplo.zip (3 capítulos)',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 3,
        currentChapter: 'Capítulo 3',
        progressPercent: 100,
        outputs: [
          { name: 'Livro_de_Exemplo.zip', url: zipUrl },
          { name: '001 - Capítulo 1.mp3', url: chapter1, durationSeconds: 180 },
          { name: '002 - Capítulo 2.mp3', url: chapter2, durationSeconds: 240 },
          { name: '003 - Capítulo 3.mp3', url: chapter3, durationSeconds: 300 },
        ],
      },
    ];

    for (const step of steps) {
      await sleep(1800);
      options.onSnapshot?.(step);
      if (step.state === 'finished') {
        return step;
      }
    }

    return steps[steps.length - 1];
  }
}

export const conversionClient = new HttpConversionClient();
export const mockConversionClient = new MockConversionClient();
