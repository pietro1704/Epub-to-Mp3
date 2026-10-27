import { AudioChunkEntry } from '../types/conversion';
import { PLAYBACK_RATES } from './playback_preferences';
import type { StreamingAudioPlayerScope } from './useChapterStreamSession';
import { useNativePlayback } from '../services/NativePlaybackPresentation';
import { useTranslations } from '../i18n/I18nProvider';

export function StreamingAudioPlayerView({
  jobId,
  chapters,
  manifest,
  currentSegment,
  waiting,
  locale,
  embedded,
  isPlaying,
  currentChapterLabel,
  started,
  hideStartButton,
  handleStart,
  sortedChapters,
  handlePrevChapter,
  currentChapter,
  handleNextChapter,
  playbackRate,
  setPlaybackRate,
  handleChapterJump,
  handleStop,
  audioRef,
  handleEnded,
  handlePlay,
  handlePause,
  handleCanPlay,
  handleTimeUpdate,
  src,
  error,
  currentSegmentText,
}: StreamingAudioPlayerScope): JSX.Element | null {
  const nativePlayback = useNativePlayback(jobId);
  const nativeLabels = useTranslations().form.ttsPreferences;
  const nativeStatus = nativePlayback && nativePlayback.phase !== 'idle'
    ? nativeLabels.nativeStates[nativePlayback.phase]
    : null;
  if (!jobId || !chapters || chapters.length === 0) {
    return null;
  }

  const currentProgress = manifest?.chunks
    ? `${currentSegment + 1} / ${manifest.chunks.length}`
    : waiting
      ? locale === 'pt'
        ? 'Aguardando'
        : 'Waiting...'
      : locale === 'pt'
        ? 'Pronto'
        : 'Ready';

  const title = locale === 'pt' ? 'Leitura contínua' : 'Sequential Player';

  const idleChapterLabel = locale === 'pt' ? 'Selecione um capítulo' : 'Select a chapter';

  const listenNowLabel =
    locale === 'pt' ? 'Ouvir agora em sequência' : 'Listen now (sequential streaming)';

  const prevChapterLabel = locale === 'pt' ? 'Capítulo anterior' : 'Prev chapter';

  const nextChapterLabel = locale === 'pt' ? 'Próximo capítulo' : 'Next chapter';

  const stopLabel = locale === 'pt' ? 'Parar' : 'Stop';

  const speedLabel = locale === 'pt' ? 'Velocidade' : 'Speed';

  const jumpLabel = locale === 'pt' ? 'Ir para' : 'Jump to';

  const openReaderHint =
    locale === 'pt'
      ? 'Use o leitor para começar a reprodução.'
      : 'Open the reader above to start the book.';

  const waitingLabel =
    locale === 'pt' ? 'Aguardando próximo trecho...' : 'Waiting for next segment...';

  const readyLabel = locale === 'pt' ? 'Pronto para começar' : 'Ready to start';

  const segmentLabel = locale === 'pt' ? `Trecho ${currentProgress}` : `Segment ${currentProgress}`;

  const currentSegmentTextLabel = locale === 'pt' ? 'Trecho atual' : 'Current segment text';

  const chunksLabel = locale === 'pt' ? 'Trechos do capítulo atual' : 'Current chapter segments';

  return (
    <div className={`streaming-player${embedded ? ' streaming-player--embedded' : ''}`}>
      <div className="streaming-player__header">
        <div>
          <div className="streaming-player__title">
            {nativeStatus ? (nativePlayback?.phase === 'playing' ? '▶' : '❚❚') : isPlaying ? '▶' : '❚❚'} {title}
          </div>
          <div className="streaming-player__chapter">{nativeStatus
            ? chapters.find(chapter => chapter.index === nativePlayback?.chapterIndex)?.name || idleChapterLabel
            : currentChapterLabel || idleChapterLabel}</div>
        </div>
        {!nativeStatus && !started && !hideStartButton ? (
          <button
            type="button"
            className="button"
            onClick={handleStart}
            disabled={!jobId || sortedChapters.length === 0}
          >
            {listenNowLabel}
          </button>
        ) : !nativeStatus && started ? (
          <div className="streaming-player__controls">
            <button
              type="button"
              className="button-secondary"
              onClick={handlePrevChapter}
              disabled={currentChapter === sortedChapters[0]?.index}
            >
              {prevChapterLabel}
            </button>
            <button
              type="button"
              className="button-secondary"
              onClick={handleNextChapter}
              disabled={currentChapter === sortedChapters[sortedChapters.length - 1]?.index}
            >
              {nextChapterLabel}
            </button>
            <label className="streaming-player__speed">
              <span>{speedLabel}</span>
              <select
                value={playbackRate}
                onChange={(e) => setPlaybackRate(Number(e.target.value))}
              >
                {PLAYBACK_RATES.map((rate) => (
                  <option key={rate} value={rate}>
                    {rate}x
                  </option>
                ))}
              </select>
            </label>
            <label className="streaming-player__jump">
              <span>{jumpLabel}</span>
              <select
                value={currentChapter}
                onChange={(e) => handleChapterJump(Number(e.target.value))}
              >
                {sortedChapters.map((ch) => (
                  <option key={ch.index} value={ch.index}>
                    {ch.index}. {ch.name}
                  </option>
                ))}
              </select>
            </label>
            <button type="button" className="button-secondary" onClick={handleStop}>
              {stopLabel}
            </button>
          </div>
        ) : !nativeStatus ? (
          <div className="streaming-player__controls streaming-player__controls--passive">
            <span className="streaming-player__hint">{openReaderHint}</span>
          </div>
        ) : null}
      </div>

      <div className="streaming-player__body">
        <audio
          hidden={Boolean(nativeStatus)}
          ref={audioRef}
          controls
          onEnded={handleEnded}
          onPlay={handlePlay}
          onPause={handlePause}
          onCanPlay={handleCanPlay}
          onTimeUpdate={handleTimeUpdate}
          style={{ width: '100%', display: nativeStatus ? 'none' : undefined }}
        />
        <div className="streaming-player__meta">
          <span>{nativeStatus ?? (waiting ? waitingLabel : src ? segmentLabel : readyLabel)}</span>
          {nativeStatus && nativePlayback?.voice && nativePlayback.phase !== 'failed' && (
            <span>{nativePlayback.voice}</span>
          )}
          {!nativeStatus && error && <span className="streaming-player__error">{error}</span>}
        </div>

        {!nativeStatus && currentSegmentText && (
          <div className="streaming-player__text">
            <div className="streaming-player__text-label">{currentSegmentTextLabel}</div>
            <div className="streaming-player__text-content">{currentSegmentText}</div>
          </div>
        )}
      </div>

      {!nativeStatus && manifest?.chunks && manifest.chunks.length > 0 && (
        <div className="streaming-player__chunks">
          <div className="streaming-player__chunks-label">{chunksLabel}</div>
          <div className="streaming-player__chunks-list">
            {manifest.chunks.map((chunk: AudioChunkEntry) => (
              <span
                key={`chunk-${chunk.index}`}
                className={`streaming-player__chip ${
                  chunk.index === currentSegment ? 'is-active' : ''
                } ${chunk.index < currentSegment ? 'is-completed' : ''}`}
              >
                #{chunk.index + 1}
              </span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
