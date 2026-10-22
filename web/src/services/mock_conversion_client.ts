import {
  ConversionFormValues,
  JobSnapshot,
  ChapterStreamManifest,
  BookTextDocument,
} from '../types/conversion';
import type {
  ConversionClient,
  FullTextResult,
  PollOptions,
  ResumableJob,
  RestartOptions,
} from './conversion_client_contract';
import { sleep } from './http_conversion_response';

export class MockConversionClient implements ConversionClient {
  private jobCounter = 0;

  private createMockAudio(chapterName: string, durationSeconds: number): string {
    // Create a simple audio context to generate a beep tone
    const webkitAudioContext = (window as Window & { webkitAudioContext?: typeof AudioContext })
      .webkitAudioContext;
    const AudioContextCtor = window.AudioContext ?? webkitAudioContext;
    if (!AudioContextCtor) {
      throw new Error('AudioContext is not supported in this environment.');
    }
    const audioContext = new AudioContextCtor();
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
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    this.jobCounter++;
    const jobId = `mock-job-${this.jobCounter}`;
    console.log('[MockClient] Conversion started:', { jobId, request });
    return { jobId };
  }

  async cancel(_jobId: string): Promise<{ status: string }> {
    return { status: 'cancelled' };
  }

  async resume(_jobId: string): Promise<{ status: string }> {
    return { status: 'queued' };
  }

  async removeJob(_jobId: string): Promise<{ status: string }> {
    return { status: 'deleted' };
  }

  async restartBackend(_options?: RestartOptions): Promise<{ status: string }> {
    return { status: 'restarting' };
  }

  async fetch(jobId: string): Promise<JobSnapshot> {
    return {
      jobId,
      state: 'queued',
      events: ['Mock: Job received', 'Mock: Processing started'],
    };
  }

  async getResumableJobs(): Promise<ResumableJob[] | null> {
    return [];
  }

  async getChapterManifest(
    _jobId: string,
    _chapterIndex: number,
  ): Promise<ChapterStreamManifest | null> {
    return null;
  }

  async getJobFullText(_jobId: string): Promise<BookTextDocument | null> {
    return null;
  }

  async getJobFullTextResult(_jobId: string): Promise<FullTextResult> {
    return { kind: 'missing', status: 404 };
  }

  private createMockZip(bookTitle: string): string {
    // Create a simple ZIP-like file with mock content
    const content = `Mock Audiobook ZIP: ${bookTitle}

This ZIP file would contain:
- 001 - Chapter 1.mp3
- 002 - Chapter 2.mp3
- 003 - Chapter 3.mp3

Generated: ${new Date().toISOString()}
Note: In production, this would be a real ZIP with all MP3 files.
`;
    const blob = new Blob([content], { type: 'application/zip' });
    return URL.createObjectURL(blob);
  }

  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    const bookTitle = 'Livro_de_Exemplo';
    const coverUrl =
      'https://images.unsplash.com/photo-1524995997946-a1c2e315a42f?w=720&auto=format&fit=crop';

    // Create individual chapter MP3s with different durations
    const chapter1 = this.createMockAudio('001 - Chapter 1', 3);
    const chapter2 = this.createMockAudio('002 - Chapter 2', 4);
    const chapter3 = this.createMockAudio('003 - Chapter 3', 5);
    const zipUrl = this.createMockZip(bookTitle);

    const parallelSlots = 3;
    const steps: JobSnapshot[] = [
      {
        jobId,
        state: 'running',
        events: [
          '📚 EBOOK METADATA',
          '================================================================',
          '📜 Title: Sample Book',
          '✍️ Author: Unknown Author',
          '📊 Chapters: 3',
          '📝 Total characters: 12,450',
        ],
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 5,
        bookTitle: 'Sample Book',
        bookAuthor: 'Unknown Author',
        coverUrl,
        parallelSlots,
        parallelActive: 0,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 EBOOK METADATA',
          '================================================================',
          '📜 Title: Sample Book',
          '✍️ Author: Unknown Author',
          '📊 Chapters: 3',
          '📝 Total characters: 12,450',
          '',
          '🌐 LANGUAGE DETECTION',
          '----------------------------------------------------------------',
          '🌐 Primary language: pt-BR (confidence: High)',
          '   Probability: 95.2%',
          '🔍 Analyzed characters: 12,450',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 15,
        bookTitle: 'Sample Book',
        bookAuthor: 'Unknown Author',
        coverUrl,
        parallelSlots,
        parallelActive: 0,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 EBOOK METADATA',
          '================================================================',
          '📜 Title: Sample Book',
          '✍️ Author: Unknown Author',
          '📊 Chapters: 3',
          '📝 Total characters: 12,450',
          '',
          '🌐 LANGUAGE DETECTION',
          '----------------------------------------------------------------',
          '🌐 Primary language: pt-BR (confidence: High)',
          '   Probability: 95.2%',
          '🔍 Analyzed characters: 12,450',
          '',
          '🔄 Automatic sequential mode: processing one chapter at a time',
          '🎯 Converting chapter 1/3: Chapter 1',
          'Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 1,
        currentChapter: 'Chapter 1',
        progressPercent: 33,
        bookTitle: 'Sample Book',
        bookAuthor: 'Unknown Author',
        coverUrl,
        parallelSlots,
        parallelActive: 1,
      },
      {
        jobId,
        state: 'running',
        events: [
          '📚 EBOOK METADATA',
          '================================================================',
          '📜 Title: Sample Book',
          '✍️ Author: Unknown Author',
          '📊 Chapters: 3',
          '📝 Total characters: 12,450',
          '',
          '🌐 LANGUAGE DETECTION',
          '----------------------------------------------------------------',
          '🌐 Primary language: pt-BR (confidence: High)',
          '   Probability: 95.2%',
          '🔍 Analyzed characters: 12,450',
          '',
          '🚀 Automatic parallel: up to 3 simultaneous chapters',
          '🎯 Converting chapter 1/3: Chapter 1',
          'Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s',
          '✅ Completed: 001 - Chapter 1.mp3',
          '',
          '🎯 Converting chapter 2/3: Chapter 2',
          '🎯 Converting chapter 3/3: Chapter 3',
          'Processing: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 0m 22s',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 2,
        currentChapter: 'Chapter 2',
        progressPercent: 67,
        bookTitle: 'Sample Book',
        bookAuthor: 'Unknown Author',
        coverUrl,
        parallelSlots,
        parallelActive: 2,
      },
      {
        jobId,
        state: 'finished',
        events: [
          '📚 EBOOK METADATA',
          '================================================================',
          '📜 Title: Sample Book',
          '✍️ Author: Unknown Author',
          '📊 Chapters: 3',
          '📝 Total characters: 12,450',
          '',
          '🌐 LANGUAGE DETECTION',
          '----------------------------------------------------------------',
          '🌐 Primary language: pt-BR (confidence: High)',
          '   Probability: 95.2%',
          '🔍 Analyzed characters: 12,450',
          '',
          '🚀 Automatic parallel: up to 3 simultaneous chapters',
          '🎯 Converting chapter 1/3: Chapter 1',
          'Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s',
          '✅ Completed: 001 - Chapter 1.mp3',
          '',
          '🎯 Converting chapter 2/3: Chapter 2',
          'Processing: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 0m 22s',
          '✅ Completed: 002 - Chapter 2.mp3',
          '',
          '🎯 Converting chapter 3/3: Chapter 3',
          'Processing: [██████████████████████████████] 100.0% (3/3) ETA: 0m 0s',
          '✅ Completed: 003 - Chapter 3.mp3',
          '',
          '📦 Creating ZIP file: Livro_de_Exemplo.zip',
          '✅ Conversion finished in 1m 8s',
          '📁 Available file: Livro_de_Exemplo.zip (3 chapters)',
        ],
        detectedLanguage: 'pt-BR',
        chaptersTotal: 3,
        chaptersCompleted: 3,
        currentChapter: 'Chapter 3',
        progressPercent: 100,
        outputs: [
          { name: 'Livro_de_Exemplo.zip', url: zipUrl },
          { name: '001 - Chapter 1.mp3', url: chapter1, durationSeconds: 180 },
          { name: '002 - Chapter 2.mp3', url: chapter2, durationSeconds: 240 },
          { name: '003 - Chapter 3.mp3', url: chapter3, durationSeconds: 300 },
        ],
        bookTitle: 'Sample Book',
        bookAuthor: 'Unknown Author',
        coverUrl,
        parallelSlots,
        parallelActive: 0,
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
